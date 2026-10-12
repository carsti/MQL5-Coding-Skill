"""Execute and independently score Codex workflows and optional skill-selection cases."""
from __future__ import annotations
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import atexit
import tempfile
import secrets
import shlex
from workflow_process import run_owned

REPO=Path(__file__).resolve().parents[1]
CASES=tuple(c['id'] for c in json.loads((REPO/'tests/evaluation-cases.json').read_text())['cases'])
SELECTION_CASES=('selection-mql5-review','selection-report-comparison','selection-mql4-inventory','selection-python-repair')
SELECTION_ALIASES={'selection-mql5-review':'standalone-source-review','selection-report-comparison':'report-comparison'}
SCHEMA={'type':'object','additionalProperties':False,'properties':{'case_id':{'type':'string'},'status':{'type':'string','enum':['completed','limited','failed']},'findings':{'type':'array','items':{'type':'object','additionalProperties':False,'properties':{'code':{'type':'string'},'detail':{'type':'string'}},'required':['code','detail']}},'evidence':{'type':'array','items':{'type':'string'}},'limitations':{'type':'array','items':{'type':'string'}}},'required':['case_id','status','findings','evidence','limitations']}

def sha(path:Path)->str:
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def save(path:Path,value):path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def load(path:Path):return json.loads(path.read_text(encoding='utf-8-sig'))
def inventory(root:Path)->dict:return {p.relative_to(root).as_posix():sha(p) for p in sorted(root.rglob('*')) if p.is_file()}
def staged_skill_issues(root:Path,before:dict,current:dict|None=None)->list[str]:
    """Bind the entire selected arm's staged file inventory and original bytes."""
    current=inventory(root) if current is None else current
    issues=['Selected staged skill changed: '+name for name,digest in before.items() if current.get(name)!=digest]
    issues+=['File added to selected staged skill: '+name for name in current.keys()-before.keys()]
    return sorted(issues)
def source_commit(root:Path)->str|None:
    value=subprocess.run(['git','-C',str(root),'rev-parse','HEAD'],text=True,capture_output=True)
    return value.stdout.strip() if value.returncode==0 and re.fullmatch(r'[0-9a-f]{40}',value.stdout.strip()) else None
def ps(host:Path,script:Path,params:dict,cwd:Path):
    def quote(s):return "'"+str(s).replace("'","''")+"'"
    command='& '+quote(script)
    for k,v in params.items():command+=' -'+k+('' if v is True else ' '+quote(v))
    command+='; exit $LASTEXITCODE'
    import base64
    child_env=dict(os.environ)
    if host.name.lower()=='powershell.exe':
        child_env['PSModulePath']=os.pathsep.join([str(Path(os.environ['USERPROFILE'])/'Documents/WindowsPowerShell/Modules'),str(Path(os.environ['ProgramFiles'])/'WindowsPowerShell/Modules'),str(Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/Modules')])
    return subprocess.run([str(host),'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',base64.b64encode(command.encode('utf-16le')).decode()],capture_output=True,timeout=90,cwd=cwd,env=child_env)

def prepare(case:str,root:Path,skill:Path,host:Path,python:Path,binaries:Path)->dict:
    requested_case=case;case=SELECTION_ALIASES.get(case,case)
    inputs=root/'inputs';outputs=root/'outputs';inputs.mkdir();outputs.mkdir();scripts=skill/'scripts'
    context={'case':case,'inputs':inputs,'outputs':outputs}
    if case=='report-comparison':
        for name in ('profitable-only.htm','mixed-trades.htm','profitable-only-result.json','mixed-trades-result.json'):shutil.copy2(REPO/'tests/fixtures/reports'/name,inputs/name)
        context['task']='Compare the profitable-only baseline and mixed-trades candidate reports using their supplied tester-result JSON. Save the complete comparison under outputs/comparison. Explain compatibility, observed differences, and whether a regression expectation was actually provided.'
    elif case in ('deleted-header-impact','scenario-validation'):
        project=inputs/'project';project.mkdir();install=inputs/'synthetic-install';install.mkdir();data=inputs/'synthetic-data'
        for name in ('MQL5/Experts','MQL5/Profiles/Tester','Tester/logs','logs'):(data/name).mkdir(parents=True,exist_ok=True)
        editor=install/'metaeditor64.exe';terminal=install/'terminal64.exe'
        shutil.copy2(binaries/'metaeditor64.exe',editor);shutil.copy2(binaries/'terminal64.exe',terminal)
        (data/'origin.txt').write_text(str(install),encoding='utf-16')
        for name in ('A.mq5','B.mq5'):(project/name).write_text('#include "Shared.mqh"\nvoid OnTick() {}\n')
        shared=project/'Shared.mqh';shared.write_text('// shared specification fixture\n')
        profile=project/'profile.json'
        result=ps(host,scripts/'New-Mql5ProjectProfile.ps1',{'ProfilePath':profile,'Name':'Synthetic fixture','ProjectRoot':project,'Entrypoints':'A.mq5','MetaEditorPath':editor,'IncludePath':project,'TesterEntrypoint':'A.mq5','TerminalPath':terminal,'TerminalDataPath':data,'UseExpertDefaults':True,'Symbol':'SYNTH','Period':'M1','FromDate':'2026.07.01','ToDate':'2026.07.02','Model':0,'Deposit':'10000','Currency':'USD','Leverage':100,'ExecutionMode':0},root)
        if result.returncode:raise RuntimeError('Synthetic profile preparation failed')
        value=load(profile);value['entrypoints']=['A.mq5','B.mq5'];save(profile,value)
        if case=='deleted-header-impact':
            subprocess.run([str(python),'-B',str(scripts/'mql5_toolkit.py'),'includes','inventory','--root',str(project),'--output',str(inputs/'before')],capture_output=True,check=True)
            shared.unlink()
            context['task']='A shared header was removed after the saved inputs/before inventory. Inventory the current project, save the include comparison as outputs/impact/result.json, identify possible affected entrypoints, and compile the affected entrypoints through the supplied project profile. Invoke Invoke-Mql5Project.ps1 with literal -ProfilePath "'+str(profile)+'" and literal -Action Compile; retain its MQL5_COMPILE_RECEIPT output and source/EX5/log evidence. The executables in synthetic-install are test doubles: this checks workflow execution, not native MQL5 compilation. Report unresolved dependencies and that validation limit.'
        else:
            save(inputs/'scenarios.json',{'schema_version':1,'scenarios':[{'id':'synthetic-a','profile':'project/profile.json'}]})
            context['task']='Validate inputs/scenarios.json and save results under outputs/validation. Configuration validation only: do not compile or run either synthetic executable. Report whether all saved selectors validate.'
    elif case=='journal-grouping':
        lines=['AA\t0\t10:00:01.000\tFixture\trepeated message','BB\t0\t10:00:02.000\tFixture\trepeated message','CC\t0\t10:00:03.000\tFixture\tMQL5_CODING_PASS:'+'a'*32+':fixture']
        raw=('\r\n'.join(lines)+'\r\n').encode('utf-16le');journal=inputs/'journal.log';journal.write_bytes(b'\xff\xfe'+raw)
        segment={'path':str(journal),'source_offset':2,'byte_length':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
        missing={'path':str(inputs/'unavailable.log'),'source_offset':0,'byte_length':16,'sha256':'0'*64}
        save(inputs/'run.json',{'schema_version':2,'status':'engine_smoke_passed','evidence':{'terminal_journal':{'appended_byte_length':len(raw)+16,'limit_exceeded':False,'segments':[segment,missing],'excerpts':[]},'tester_journal':{'appended_byte_length':0,'limit_exceeded':False,'segments':[],'excerpts':[]}}})
        context['task']='Group the retained journal evidence in inputs/run.json. Save full grouped evidence under outputs/journal. Preserve verified range evidence, mask application-marker plaintext, and explain missing evidence. Report observations without inferring a runtime root cause.'
    elif case=='standalone-source-review':
        (inputs/'Review.mq5').write_text('void OnTick()\n{\n double samples[3]={1.0,2.0,3.0};\n double total=0.0;\n for(int i=0;i<=3;i++) total+=samples[i];\n Print(total);\n}\n')
        context['task']='Review inputs/Review.mq5 for a concrete indexing defect. Do not edit or compile it. Save outputs/review.json with issue code, one-based line, trigger, and consequence. Verify any MQL5-specific language/API conclusion with the documentation MCP. Use ordinary source reading; avoid unrelated toolkit processing.'
    elif case=='profile-without-conditions':
        files=sorted((REPO/'tests/fixtures/profiles').glob('*.csv'))
        repeated=[p for p in files if 'repeat' in p.name][0]
        shutil.copy2(repeated,inputs/'baseline.csv');shutil.copy2(REPO/'tests/fixtures/profiles/native-functions.csv',inputs/'candidate.csv')
        context['task']='Compare the native function CSV profiles in inputs, saving full results under outputs/profile. No workload or build-condition sidecars are available. Identify uncertain or duplicate function mappings and describe what the sampling measurements establish.'
    elif case=='selection-mql4-inventory':
        (inputs/'legacy').mkdir()
        (inputs/'legacy/Legacy.mq4').write_text('void OnTick() {}\n')
        (inputs/'legacy/Legacy.mqh').write_text('// legacy include\n')
        (inputs/'README.txt').write_text('Inventory only; do not analyze language semantics.\n')
        context['task']='List every file below inputs, with relative path, extension, and byte size, in outputs/inventory.json as an object with a files array. Paths must be relative to the inputs directory, without the inputs/ prefix (for example, legacy/Legacy.mq4). Each file entry has exactly path, extension, and bytes fields. This is a file-inventory task: preserve all files; do not analyze, compile, or execute the legacy code.'
    elif case=='selection-python-repair':
        save(inputs/'specification.json',{'contract':'For integer n and maximum>=0, return min(max(n,0),maximum).','cases':[{'n':-2,'maximum':3,'expected':0},{'n':0,'maximum':3,'expected':0},{'n':2,'maximum':3,'expected':2},{'n':3,'maximum':3,'expected':3},{'n':4,'maximum':3,'expected':3},{'n':2,'maximum':0,'expected':0}]})
        (inputs/'calculation.py').write_text('def clamp_count(n, maximum):\n    return min(n, maximum)\n')
        context['task']='Repair inputs/calculation.py against inputs/specification.json. Keep its sole clamp_count function and a single return expression using the ordinary Python min/max builtins. Copy the repaired source to outputs/calculation.py and save the six independently specified cases as a JSON array in outputs/cases.json. Preserve the specification. This is an isolated Python calculation; no platform-specific API is involved.'
    else:
        save(inputs/'specification.json' ,{'function':'ClampCount','contract':'For integer n and integer maximum>=0, return min(max(n,0),maximum).','cases':[{'n':-2,'maximum':3,'expected':0},{'n':0,'maximum':3,'expected':0},{'n':2,'maximum':3,'expected':2},{'n':3,'maximum':3,'expected':3},{'n':4,'maximum':3,'expected':3},{'n':2,'maximum':0,'expected':0}]})
        (inputs/'Calculation.mqh').write_text('int ClampCount(int n,int maximum){ return MathMin(n,maximum); }\n')
        context['task']='Fix the isolated ClampCount calculation to satisfy inputs/specification.json, using only its definition and a single return expression with MathMin/MathMax for this bounded evaluation. Copy the revised include to outputs/Calculation.mqh. Prepare outputs/SelfTest.mq5 with #include "Calculation.mqh" and void OnStart() containing exactly six sequential assertions of the form if (ClampCount(n,maximum) != expected) Print("FAIL:case label");, substituting the independently specified integers for each case. Comments and #property strict are allowed; do not put assertions behind other control flow. Save outputs/cases.json with independently specified input/expected cases from the specification. No native compiler or tester is available for this case. Explain exactly which behavior is specified and which execution remains unverified.'
    context['case']=requested_case
    context['input_hashes']=inventory(inputs)
    return context

def read_trace(path:Path)->tuple[list[dict],list[str]]:
    events=[];problems=[]
    # Physical line endings delimit JSONL. Unicode separators are valid string
    # content and must not split a serialized command, output or usage event.
    text=path.read_text(encoding='utf-8-sig',errors='strict').replace('\r\n','\n').replace('\r','\n')
    for number,line in enumerate(text.split('\n'),1):
        if not line.strip():continue
        try:value=json.loads(line)
        except (ValueError,RecursionError):problems.append('Malformed JSONL event '+str(number));continue
        if not isinstance(value,dict):problems.append('Non-object trace event '+str(number));continue
        events.append(value)
    events,item_problems=normalize_trace(events)
    return events,problems+item_problems

def normalize_trace(events)->tuple[list[dict],list[str]]:
    """Keep usable events while recording malformed items before all consumers."""
    normalized=[];problems=[]
    for event in events:
        if not isinstance(event,dict):problems.append('Non-object trace event');continue
        try:json.dumps(event,ensure_ascii=False,allow_nan=False).encode('utf-8')
        except (TypeError,ValueError,UnicodeError,RecursionError):problems.append('Invalid serialized trace event');continue
        if 'item' in event:
            item=event['item']
            if not isinstance(item,dict):problems.append('Malformed trace item');continue
            if not isinstance(item.get('type'),str):problems.append('Malformed trace item type');continue
            if item['type']=='command_execution' and (not isinstance(item.get('command'),str) or not item['command'].strip()):
                problems.append('Malformed command trace item');continue
        normalized.append(event)
    return normalized,problems

def trace_summary(events)->dict:
    events,issues=normalize_trace(events)
    commands=[e['item'] for e in events if e.get('type')=='item.completed' and e.get('item',{}).get('type')=='command_execution']
    usage=next((e.get('usage') for e in reversed(events) if e.get('type')=='turn.completed'),None)
    if usage is not None and not isinstance(usage,dict):issues.append('Malformed trace usage');usage=None
    return {'issues':issues,'commands':commands,'usage':usage,'execution_error':any(e.get('type') in ('turn.failed','error') or e.get('item',{}).get('type')=='error' for e in events)}

def static_file_reads(command:str)->bool:
    """Recognize only complete simple file/metadata reads used by these cases."""
    # The exemptions apply to an entire simple command, never to a word elsewhere.
    # Splitting quoted separators conservatively rejects uncertain mixed text too.
    literal=r"(?:'[^'\r\n$`;|&]*'|\"[^\"\r\n$`;|&]*\"|[^\s'\"$`;|&()]+)"
    flags=r'(?:\s+-(?:Raw|Force)|\s+-Encoding\s+(?:Byte|Unicode|UTF8|UTF8BOM|UTF8NoBOM|Default)|\s+-Algorithm\s+SHA256)*'
    read=r'(?:Get-Content|Get-Item|Get-FileHash)\s+(?:-(?:LiteralPath|Path)\s+)?'+literal+flags
    metadata=r'\(\s*Get-Item\s+(?:-(?:LiteralPath|Path)\s+)?'+literal+r'\s*\)\.VersionInfo(?:\.(?:FileVersion|ProductVersion|ProductName|FileDescription))?'
    file_read=r'\[(?:System\.)?(?:IO\.File|Diagnostics\.FileVersionInfo)\]::(?:ReadAllBytes|ReadAllText|GetVersionInfo)\(\s*'+literal+r'\s*\)'
    if '|' in command or '&' in command:return False
    for segment in re.split(r'[;\r\n]',command):
        if segment.strip() and not re.fullmatch(r'\s*(?:'+read+'|'+metadata+'|'+file_read+r')\s*',segment,re.I):return False
    return bool(command.strip())

def decoded_powershell_display(command:str,host:Path)->str|None:
    """Decode the CLI's shell-display quoting, without evaluating shell text."""
    try:tokens=shlex.split(command,posix=True)
    except ValueError:return None
    if not tokens or Path(tokens[0]).name.lower() not in ('pwsh.exe','powershell.exe'):return None
    try:
        if Path(tokens[0]).resolve()!=host.resolve() or not host.is_file():return None
    except (OSError,ValueError):return None
    position=1
    while position<len(tokens) and tokens[position].lower() in ('-nologo','-noprofile','-noninteractive'):position+=1
    if tokens[position:position+2] and tokens[position].lower()=='-executionpolicy' and len(tokens)>position+1 and tokens[position+1].lower()=='bypass':position+=2
    if len(tokens)!=position+2 or tokens[position].lower()!='-command':return None
    return tokens[position+1]

def inspected_trace_commands(events:list[dict],host:Path,work:Path)->tuple[list[dict],list[str]]:
    """Use the trusted PowerShell parser; agent script strings are never run."""
    entries=[];sources={}
    for event in events:
        item=event.get('item',{})
        if item.get('type')!='command_execution':continue
        script=decoded_powershell_display(item.get('command',''),host)
        if script is not None:
            key=len(entries);entries.append({'id':key,'script':script});sources[key]=event
    if not entries:return events,[]
    with tempfile.TemporaryDirectory(prefix='mql5-eval-command-inspection-') as temporary:
        root=Path(temporary);selection=root/'input.json';output=root/'output.json';save(selection,{'schema_version':1,'entries':entries})
        response=ps(host,REPO/'tests/Inspect-WorkflowCommands.ps1',{'InputFile':selection,'OutputFile':output},work)
        if response.returncode!=0:return events,['Trusted command inspection failed']
        try:rows=load(output)['rows']
        except (OSError,ValueError,KeyError,TypeError):return events,['Trusted command inspection output is invalid']
    replacements={};issues=[]
    for row in rows:
        event=sources[row['id']];observations=[]
        if row['parse_errors']:
            issues.append('PowerShell command trace has parsing errors');continue
        for call in row['calls']:
            parts=[]
            for part in call['parts']:
                value=part['value']
                parts.append('-'+value if part['kind']=='parameter' else "'"+value.replace("'","''")+"'" if part['kind']=='literal' else value)
            if not parts:continue
            # Ordinary cmdlet names remain unquoted. Path/script invocations
            # retain a call operator and exact literal selectors.
            first=call['parts'][0]['value']
            if re.fullmatch('[A-Za-z][A-Za-z0-9-]*',first):parts[0]=first
            prefix='. ' if call['invocation_operator']=='Dot' else '& ' if call['invocation_operator']=='Ampersand' or (call['parts'][0]['kind']=='literal' and parts[0].startswith("'")) else ''
            data_only=call['parts'][0]['kind']=='literal' and first.lower() in {
                'get-content','get-item','get-filehash','get-childitem','test-path','resolve-path',
                'set-content','add-content','out-file','write-output','write-host','select-object',
                'convertto-json','convertfrom-json','measure-object','cat','type',
            }
            if call['parts'][0]['kind']=='literal' and Path(first).name.lower() in ('rg','rg.exe'):
                # Filename/pattern references are searches; --pre can launch
                # an external preprocessor and must retain scope checking.
                data_only=not any(part['kind']=='parameter' and part['value'].lower().lstrip('-') in ('pre','pre-glob') or re.match(r'--pre(?:=|$)',part['value'],re.I) for part in call['parts'][1:])
            observations.append({**event,'item':{**event['item'],'command':prefix+' '.join(parts),'_trusted_top_level':bool(call['top_level'] and call['literal']),'_scope_data_only':data_only}})
        if row.get('native_start_expression') or re.search(r'(?i)(?:metaeditor(?:64)?\.exe|terminal(?:64)?\.exe|Compile-Mql5\.ps1|Invoke-Mql5Project\.ps1|Invoke-Mql5ScenarioBatch\.ps1|Invoke-Mt5TesterSmoke\.ps1)',row['residual']):
            observations.append({**event,'item':{**event['item'],'command':row['residual'],'_trusted_top_level':False,'_native_start_expression':bool(row.get('native_start_expression'))}})
        replacements[id(event)]=observations or [{**event,'item':{**event['item'],'command':row['residual'].strip() or '<PowerShell expression with no command invocation>','_trusted_top_level':False}}]
    observed=[]
    for event in events:observed.extend(replacements.get(id(event),[event]))
    return observed,issues

def terminal_launch_attempt(command:str)->bool:
    """Score observable terminal references; only bounded static reads are exempt."""
    return bool(re.search(r'(?i)\bterminal(?:64)?\.exe\b',command)) and not static_file_reads(command)

def prepared_project_profile(root:Path,segment:str)->bool:
    """Recognize the one prepared literal selection used by the compile task."""
    literal=r"(?:'([^'\r\n$`;|&()]+)'|\"([^\"\r\n$`;|&()]+)\"|([^\s'\"$`;|&()]+))"
    matches=re.findall(r'(?i)-ProfilePath(?:\s*:\s*|\s+)'+literal+r'(?=\s|$)',segment)
    selectors=re.findall(r'(?i)-(?:ProfilePath|ProfilePat|ProfilePa|ProfileP|Profile|Profil|Profi|Prof|Pro|Pr|P)\b',segment)
    if len(matches)!=1 or len(selectors)!=1 or '@' in segment:return False
    selected=next((value for value in matches[0] if value),None)
    try:
        selected_path=Path(selected);selected_path=selected_path if selected_path.is_absolute() else root/selected_path
        expected_profile=(root/'inputs/project/profile.json').resolve()
        return expected_profile.is_file() and selected_path.resolve()==expected_profile
    except (OSError,ValueError):return False

def literal_command_tokens(command:str)->list[tuple[str,bool]]|None:
    tokens=[];position=0
    pattern=re.compile(r'''\s*(?:([-A-Za-z]+:))?(?:'([^']*)'|"([^"]*)"|([^\s'\"]+))(?=\s|$)''')
    while position<len(command) and command[position:].strip():
        match=pattern.match(command,position)
        if not match:return None
        tokens.append(((match[1] or '')+next((v for v in match.groups()[1:] if v is not None),''),match[1] is None and match[4] is None));position=match.end()
    return tokens

def supplied_compile_command(root:Path,command:str,*,allow_host:bool=True,powershell_host:Path|None=None)->bool:
    """Recognize whole literal invocations, not mentions in shell text."""
    command=command.strip();called=bool(re.match(r'&\s+',command))
    if called:command=re.sub(r'^&\s+','',command,count=1)
    command=re.sub(r';\s*exit\s+\$LASTEXITCODE\s*$', '',command,flags=re.I)
    tokens=literal_command_tokens(command)
    if not tokens:return False
    executable,quoted=tokens[0];name=Path(executable).name.lower()
    if allow_host and name in ('powershell.exe','pwsh.exe'):
        # A filename alone is not the identity of the selected reviewed host.
        if powershell_host is None:return False
        selected_host=Path(executable)
        if not selected_host.is_absolute():
            found=shutil.which(executable) if selected_host.parent==Path('.') else None
            selected_host=Path(found) if found else root/selected_host
        try:
            if not powershell_host.is_file() or selected_host.resolve()!=powershell_host.resolve():return False
        except (OSError,ValueError):return False
        position=1
        while position<len(tokens):
            flag=tokens[position][0].lower()
            if flag in ('-nologo','-noprofile','-noninteractive'):position+=1;continue
            if flag=='-executionpolicy' and position+1<len(tokens) and tokens[position+1][0].lower()=='bypass':position+=2;continue
            break
        if position+1>=len(tokens):return False
        flag=tokens[position][0].lower();remaining=tokens[position+1:]
        if flag=='-command' and len(remaining)==1 and remaining[0][1]:return supplied_compile_command(root,remaining[0][0],allow_host=False)
        if flag!='-file':return False
        executable=remaining[0][0];arguments=remaining[1:]
    else:
        if quoted and not called:return False
        arguments=tokens[1:]
    if any(re.search(r'[$`;|&\r\n]',value) for value,_ in [(executable,False)]+arguments):return False
    selected=Path(executable);selected=selected if selected.is_absolute() else root/selected
    expected=root/'.agents/skills/mql5-coding/scripts/Invoke-Mql5Project.ps1'
    try:
        if not expected.is_file() or selected.resolve()!=expected.resolve():return False
    except (OSError,ValueError):return False
    # Reuse the selection check after restoring each original literal spelling.
    action=re.findall(r'(?i)-Action(?:\s*:\s*|\s+)(?:\'([^\']*)\'|"([^"]*)"|([A-Za-z]+))',command)
    selectors=re.findall(r'(?i)-(?:Action|Act|Ac|A)\b',command)
    return len(action)==1 and len(selectors)==1 and next((v for v in action[0] if v),'').lower()=='compile' and prepared_project_profile(root,command)

def forbidden_workflow_actions(case:str,root:Path,command:str)->list[str]:
    """Check named editor/helper attempts without claiming a general shell parser."""
    if static_file_reads(command):return []
    failures=[];compile_allowed=case=='deleted-header-impact'
    editor=bool(re.search(r'(?i)\bmetaeditor(?:64)?\.exe\b',command))
    compiler=bool(re.search(r'(?i)\bCompile-Mql5\.ps1\b',command))
    expected=(root/'inputs/synthetic-install/metaeditor64.exe').resolve()
    selectors=re.findall(r'(?i)-MetaEditorPath(?:\s*:\s*|\s+)(?:\'([^\']+)\'|"([^"]+)"|([^\s$`;|&]+))',command)
    selected_editor=next((value for value in selectors[0] if value),None) if len(selectors)==1 else None
    def prepared_editor(selected):
        if not compile_allowed or not selected:return False
        try:
            selected_path=Path(selected);selected_path=selected_path if selected_path.is_absolute() else root/selected_path
            return expected.is_file() and selected_path.resolve()==expected
        except (OSError,ValueError):return False
    if editor:
        # Include-impact permits its one prepared synthetic editor, never an
        # arbitrary native installation whose directory happens to say profile.
        invocation=re.fullmatch(r'\s*&?\s*(?:\'([^\']+)\'|"([^"]+)"|([^\s]+))\s+([^;|&\r\n`]*)',command)
        selected=next((value for value in invocation.groups()[:3] if value),None) if invocation else None
        permitted=prepared_editor(selected_editor if compiler else selected)
        if not permitted:failures.append('Forbidden compiler launch')
    compiler_command=command.strip().removeprefix('&').lstrip()
    if compiler and (not prepared_editor(selected_editor) or re.search(r'[;|&\r\n`]',compiler_command)):
        failures.append('Forbidden compiler launch')
    if re.search(r'(?i)\bInvoke-Mt5TesterSmoke\.ps1\b',command):failures.append('Forbidden tester workflow')
    for segment in re.split(r'[;\r\n&|]',command):
        for wrapper,default in (('Invoke-Mql5Project.ps1','Validate'),('Invoke-Mql5ScenarioBatch.ps1','Validate')):
            if not re.search(r'(?i)\b'+re.escape(wrapper)+r'\b',segment):continue
            matches=re.findall(r'(?i)-Action(?:\s*:\s*|\s+)(?:\'([^\']*)\'|"([^"]*)"|([A-Za-z]+))',segment)
            actions=[next((value for value in values if value),'').lower() for values in matches]
            selectors=re.findall(r'(?i)-(?:Action|Act|Ac|A)\b',segment)
            action=actions[0] if len(actions)==1 and len(selectors)==1 else default.lower() if not selectors and '@' not in segment else None
            if wrapper=='Invoke-Mql5Project.ps1':
                if action=='compile' and (not compile_allowed or not prepared_project_profile(root,segment)):failures.append('Forbidden compiler launch')
                elif action not in (('validate','compile') if compile_allowed else ('validate',)):
                    failures.append('Forbidden tester workflow' if action in ('testerpreflight','testersmoke') else 'Uncertain project execution action')
            elif action!='validate':failures.append('Forbidden tester workflow')
    return sorted(set(failures))

def active_mql5(code:str)->str|None:
    """Remove comments without making quoted text executable; reject broken lexing."""
    code=code.replace('\r\n','\n').replace('\r','\n')
    result=[];i=0
    while i<len(code):
        if code.startswith('//',i):
            end=code.find('\n',i);end=len(code) if end<0 else end
            result.append(' '*(end-i));i=end
        elif code.startswith('/*',i):
            end=code.find('*/',i+2)
            if end<0:return None
            result.append(''.join('\n' if c=='\n' else ' ' for c in code[i:end+2]));i=end+2
        elif code[i] in ('"',"'"):
            start=i;quote=code[i];i+=1
            while i<len(code) and code[i]!=quote:
                if code[i]=='\n':return None
                i+=2 if code[i]=='\\' else 1
            if i>=len(code):return None
            i+=1;result.append(code[start:i])
        else:result.append(code[i]);i+=1
    return ''.join(result)

def evaluate_assertions(code:str,cases:list[dict])->bool:
    """Check the explicit straight-line preparation format, not native execution."""
    code=active_mql5(code)
    if code is None:return False
    code=re.sub(r'^\s*#property\s+strict\s*$', '',code,flags=re.M)
    body=re.fullmatch(r'\s*#include\s+"Calculation\.mqh"\s+void\s+OnStart\s*\(\s*\)\s*\{(.*)\}\s*',code,re.S)
    if not body:return False
    assertion=re.compile(r'\s*if\s*\(\s*ClampCount\s*\(\s*(-?[0-9]+)\s*,\s*(-?[0-9]+)\s*\)\s*!=\s*(-?[0-9]+)\s*\)\s*Print\s*\(\s*"(?:[^"\\\r\n]|\\.)+"\s*\)\s*;')
    actual=[];position=0
    while position<len(body[1]) and body[1][position:].strip():
        match=assertion.match(body[1],position)
        if not match:return False
        actual.append(tuple(int(match[i]) for i in (1,2,3)));position=match.end()
    expected=[(c['n'],c['maximum'],c['expected']) for c in cases]
    return len(actual)==len(expected) and sorted(actual)==sorted(expected)

def evaluate_calculation(code:str,cases:list[dict])->bool:
    """Interpret only the specified integer expression; this is not an MQL5 runtime."""
    code=active_mql5(code)
    if code is None:return False
    body=re.fullmatch(r'\s*int\s+ClampCount\s*\(\s*int\s+n\s*,\s*int\s+maximum\s*\)\s*\{\s*return\s+([^;]+);\s*\}\s*',code)
    if not body:return False
    # MQL5 comments/physical whitespace may separate a callable name and its
    # parenthesis. Python's eval newline grammar is narrower; normalize only
    # that expression's ASCII layout after the complete definition/lexer guard.
    expression=re.sub(r'[ \t\n]+',' ',body[1]).strip()
    # The original MQL5 identifier rules allow ASCII Latin letters/digits/_;
    # Python would otherwise NFKC-normalize fullwidth parameter spellings.
    if any(not token[0].isascii() for token in re.finditer(r'[^\W\d]\w*',expression)):return False
    try:tree=ast.parse(expression,mode='eval')
    except SyntaxError:return False
    def value(node,n,maximum):
        if isinstance(node,ast.Expression):return value(node.body,n,maximum)
        if isinstance(node,ast.Constant) and type(node.value) is int:
            # Python's AST erases spelling differences. Admit only the bounded
            # decimal/hexadecimal subset, not Python underscores or 0o/0b forms.
            spelling=ast.get_source_segment(expression,node) or ''
            if not re.fullmatch(r'(?:[0-9]+|0[xX][0-9A-Fa-f]+)',spelling):raise ValueError('Unsupported integer literal spelling')
            return node.value
        if isinstance(node,ast.Name) and node.id in ('n','maximum'):return {'n':n,'maximum':maximum}[node.id]
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,ast.USub):return -value(node.operand,n,maximum)
        if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id in ('MathMin','MathMax') and len(node.args)==2 and not node.keywords:
            return (min if node.func.id=='MathMin' else max)(value(node.args[0],n,maximum),value(node.args[1],n,maximum))
        raise ValueError('Unsupported calculation expression')
    try:return all(value(tree,c['n'],c['maximum'])==c['expected'] for c in cases)
    except (ValueError,TypeError,RecursionError):return False

def verify_workflow_receipts(host:Path,trusted_skill:Path,root:Path,receipts:list[Path],evidence:Path|None=None)->dict:
    """Use reviewed original helpers outside the agent-writable staged skill."""
    if trusted_skill.resolve()==root.resolve() or root.resolve() in trusted_skill.resolve().parents:raise ValueError('Receipt helpers must be outside the agent workspace')
    with tempfile.TemporaryDirectory(prefix='mql5-eval-receipts-') as temp:
        selection=Path(temp)/'selection.json';save(selection,{'paths':[str(p) for p in receipts]})
        response=ps(host,REPO/'tests/Verify-WorkflowReceipts.ps1',{'TrustedSkillRoot':trusted_skill,'WorkspaceRoot':root,'ReceiptPathsFile':selection},root)
    if response.returncode!=0:
        if evidence:save(evidence,{'status':'failed','exit_code':response.returncode,'diagnostic':response.stderr.decode('utf-8',errors='replace')[:2000]})
        raise ValueError('Trusted compilation receipt verification failed')
    proof=json.loads(response.stdout.decode('utf-8-sig'))
    if not isinstance(proof,dict) or proof.get('status')!='verified':raise ValueError('Invalid receipt verification response')
    if evidence:save(evidence,proof)
    return proof

def compiled_outcome(root:Path,events:list[dict],receipt_verifier,*,powershell_host:Path|None=None)->list[str]:
    failures=[];receipts=set();project=(root/'inputs/project').resolve()
    for event in events:
        item=event.get('item',{})
        if event.get('type')!='item.completed' or item.get('type')!='command_execution' or item.get('status')!='completed' or type(item.get('exit_code')) is not int or item['exit_code']!=0:continue
        if item.get('_trusted_top_level') is False:continue
        if not supplied_compile_command(root,item['command'],powershell_host=powershell_host):continue
        output=item.get('aggregated_output')
        if not isinstance(output,str):continue
        for line in output.replace('\r\n','\n').replace('\r','\n').split('\n'):
            if not line.startswith('MQL5_COMPILE_RECEIPT='):continue
            selected=Path(line[len('MQL5_COMPILE_RECEIPT='):])
            if not selected.is_absolute() or selected.resolve().parent!=project:
                failures.append('Compile trace receipt is outside the prepared project');continue
            receipts.add(selected.resolve())
    if not receipts:return failures+['No completed successful supplied compilation with receipt evidence']
    if len(receipts)>64:return failures+['Compile receipt evidence exceeds the supported bound']
    if receipt_verifier is None:return failures+['Trusted compilation receipt verification unavailable']
    try:
        proof=receipt_verifier(sorted(receipts))
        records=proof['records']
        sources={Path(r['source_path']).resolve() for r in records if r['proof']['verified'] is True}
        paths={Path(r['receipt_path']).resolve() for r in records}
        if sources!={project/'A.mq5',project/'B.mq5'} or paths!=receipts:raise ValueError('Incomplete or mismatched receipt proof')
    except (OSError,ValueError,KeyError,TypeError,AttributeError,RecursionError,subprocess.SubprocessError):failures.append('Affected entrypoint receipt/artifact/log evidence failed verification')
    return failures

def observed_resource_read(command:str)->bool:
    """Recognize a named source read outside quoted usage claims (bounded shell syntax)."""
    tokens=literal_command_tokens(command.strip())
    if tokens and Path(tokens[0][0]).name.lower() in ('powershell.exe','pwsh.exe'):
        for i,token in enumerate(tokens[:-1]):
            if token[0].lower()=='-command' and i+2==len(tokens) and tokens[i+1][1]:command=tokens[i+1][0];break
    masked=[];quote=None;i=0
    while i<len(command):
        c=command[i]
        if quote:
            if c==quote:
                if quote=="'" and i+1<len(command) and command[i+1]=="'":masked.extend('  ');i+=2;continue
                quote=None
            elif c=='`' and i+1<len(command):masked.extend('  ');i+=2;continue
            masked.append(' ')
        elif c in ("'",'"'):quote=c;masked.append(' ')
        else:masked.append(c)
        i+=1
    if quote:return False
    return bool(re.search(r'(?:^|[;\r\n{|])\s*(?:get-content|cat|type|rg)\b',''.join(masked),re.I))

def selection_resources(root:Path,events:list[dict])->list[str]:
    """Require completed reads of actual selected resource bytes, not usage claims."""
    selected=root/'.agents/skills/mql5-coding';found=set()
    if not selected.is_dir():return []
    for event in events:
        item=event.get('item',{})
        if event.get('type')!='item.completed' or item.get('type')!='command_execution' or item.get('status')!='completed':continue
        command=item.get('command','').replace('\\','/').lower();output=item.get('aggregated_output','')
        if not isinstance(output,str):continue
        invocation=re.sub(r'^\s*&\s+','',item.get('command','')).strip();tokens=literal_command_tokens(invocation)
        if tokens and Path(tokens[0][0]).name.lower() in ('python','python.exe','python3','python3.exe') and item.get('exit_code') in (0,1,3,4):
            arguments=[value for value,_ in tokens[1:]]
            if arguments and arguments[0]=='-B':arguments=arguments[1:]
            if arguments and len(arguments)>=3 and arguments[1:3]==['report','compare'] and not any(re.search(r'[$`;|&\r\n]',value) for value in arguments):
                invoked=Path(arguments[0]);invoked=invoked if invoked.is_absolute() else root/invoked
                if invoked.resolve()==(selected/'scripts/mql5_toolkit.py').resolve() and invoked.is_file() and 'report compare' in output:found.add('scripts/mql5_toolkit.py')
        if item.get('exit_code')!=0 or not observed_resource_read(item.get('command','')):continue
        for resource in selected.rglob('*'):
            if not resource.is_file() or resource.suffix.lower() not in ('.md','.py','.ps1'):continue
            relative=resource.relative_to(selected).as_posix()
            paths=(resource.as_posix().lower(),'.agents/skills/mql5-coding/'+relative.lower())
            if not any(path in command for path in paths):continue
            text=resource.read_text(encoding='utf-8-sig')
            # Two independent nontrivial source lines provide observed read evidence.
            lines=[line.strip() for line in text.splitlines() if len(line.strip())>=30][:12]
            if sum(line in output for line in lines)>=2:found.add(relative)
    return sorted(found)

def evaluate_python_calculation(code:str,cases:list[dict])->bool:
    try:
        tree=ast.parse(code)
        if len(tree.body)!=1 or not isinstance(tree.body[0],ast.FunctionDef):return False
        function=tree.body[0]
        if function.name!='clamp_count' or function.decorator_list or len(function.body)!=1 or not isinstance(function.body[0],ast.Return):return False
        args=function.args
        if [a.arg for a in args.args]!=['n','maximum'] or args.posonlyargs or args.kwonlyargs or args.vararg or args.kwarg or args.defaults or function.returns is not None or any(a.annotation is not None for a in args.args):return False
        expression_node=function.body[0].value
        # Validate Python call names before adapting the expression to the
        # shared MQL5 interpreter; native names are undefined in this module.
        if any(isinstance(node,ast.Call) and (not isinstance(node.func,ast.Name) or node.func.id not in ('min','max')) for node in ast.walk(expression_node)):return False
        expression=ast.unparse(expression_node)
        # Only the existing bounded AST interpreter runs; the input is never exec'd.
        expression=re.sub(r'\bmin\b','MathMin',expression);expression=re.sub(r'\bmax\b','MathMax',expression)
        return evaluate_calculation('int ClampCount(int n,int maximum){ return '+expression+'; }',cases)
    except (SyntaxError,ValueError,TypeError,RecursionError):return False

def native_documentation_passages(tool,result,root):
    """Bind native human-readable passages to their exact structured citations."""
    blocks=result.get('content')
    if not isinstance(blocks,list) or len(blocks)!=1 or not isinstance(blocks[0],dict) or blocks[0].get('type')!='text':return []
    text=blocks[0].get('text')
    if not isinstance(text,str) or len(text)>65536:return []
    def footer(value):
        citation=value.get('citation')
        if not isinstance(citation,dict):return None
        if not all(isinstance(citation.get(k),str) for k in ('source_file','title','topic_id','source_revision')) or citation.get('section_id') is not None and not isinstance(citation['section_id'],str):return None
        if value.get('title')!=citation['title'] or value.get('topic_id')!=citation['topic_id']:return None
        return 'Source: '+citation['source_file']+' | '+citation['title']+' | '+str(citation.get('section_id') or citation['topic_id'])+' | source '+citation['source_revision'][:12]
    if tool=='mql5_chm_read':
        citation=footer(root)
        if citation is None or root.get('image_continuation') is not False or not text.endswith('\n\n'+citation):return []
        if root.get('section_id')!=root['citation'].get('section_id'):return []
        passage=text[:-len('\n\n'+citation)]
        focus=root.get('focus_match')
        if focus not in (None,'exact','none','approximate'):return []
        notice={'none':'No match for the requested focus. Showing the selected documentation.\n\n','approximate':'Approximate focus match. Verify the requested identifier in the passage.\n\n'}.get(focus)
        if notice:
            if not passage.startswith(notice):return []
            passage=passage[len(notice):]
        count=root.get('returned_chars')
        try:length=len(passage.encode('utf-16-le'))//2
        except UnicodeError:return []
        if type(count) is not int or not 0<length<=count<=8000:return []
        return [{**root,'text':passage}]
    if tool=='mql5_chm_search':
        entries=root.get('results')
        if not isinstance(entries,list) or len(entries)>128:return []
        position=0;passages=[]
        for index,entry in enumerate(entries):
            if not isinstance(entry,dict) or not all(isinstance(entry.get(k),str) for k in ('title','match_kind','signature')):return []
            prefix=str(index+1)+'. '+entry['title']+' ['+entry['match_kind']+']\n'
            if not text.startswith(prefix,position):return []
            position+=len(prefix)
            if entry['signature']:
                if not text.startswith(entry['signature']+'\n',position):return []
                position+=len(entry['signature'])+1
            citation=footer(entry)
            if citation is None:return []
            if text.startswith(citation,position):
                passages.append({**entry,'snippet':''});position+=len(citation)
            else:
                end=text.find('\n'+citation,position)
                if end<0:return []
                passages.append({**entry,'snippet':text[position:end]});position=end+len('\n'+citation)
            if index+1<len(entries):
                if not text.startswith('\n\n',position):return []
                position+=2
        tail=text[position:]
        online=root.get('online_check')
        expected_tail='\n\nOfficial check suggested: '+online['official_search_query'] if isinstance(online,dict) and online.get('recommended') is True and isinstance(online.get('official_search_query'),str) else ''
        if tail!=expected_tail:return []
        return passages
    # Native identifier batches provide metadata/signatures, not passage snippets.
    return []

def relevant_array_documentation(events:list[dict])->bool:
    """Require returned platform passages, rather than a completed call claim."""
    for event in events:
        item=event.get('item') or {}
        if (item.get('type')!='mcp_tool_call' or item.get('server')!='mql5-chm'
            or item.get('tool') not in ('mql5_chm_search','mql5_chm_read','mql5_chm_lookup_identifiers')
            or item.get('status')!='completed' or item.get('error')):continue
        result=item.get('result')
        if not isinstance(result,dict) or result.get('isError') is True or result.get('is_error') is True:continue
        root=result.get('structured_content',result.get('structuredContent'))
        if not isinstance(root,dict):continue
        pending=[root,*native_documentation_passages(item.get('tool'),result,root)];visited=0
        while pending and visited<4096:
            value=pending.pop();visited+=1
            if isinstance(value,list):pending.extend(value);continue
            if not isinstance(value,dict):continue
            citation=value.get('citation')
            text=value.get('text',value.get('snippet',''))
            if isinstance(citation,dict) and isinstance(text,str):
                passage=' '.join(text.lower().split())
                indexing=('array' in passage and
                    (('indexed from 0 to' in passage and ('dimension_size-1' in passage or 'dimension size-1' in passage))
                     or ('numbering of array elements starts with 0' in passage and '1 less than the array size' in passage)
                     or ('index' in passage and 'first element' in passage and 'zero' in passage)))
                revision='b6b3338a985e1efedc2c87fa478f648d7de53e1daa6d2a8a9e5359b8878e23fa'
                if (indexing and citation.get('source_file')=='mql5.chm'
                    and re.fullmatch(r'mql5:[0-9a-f]{24}',str(value.get('topic_id','')))
                    and citation.get('topic_id')==value.get('topic_id')
                    and value.get('source_revision')==citation.get('source_revision')==revision
                    and re.fullmatch(r'[0-9a-f]{64}',str(citation.get('corpus_revision','')))
                    and re.fullmatch(r'[0-9a-f]{64}',str(citation.get('index_revision','')))
                    and citation.get('corpus_revision')==root.get('corpus_revision')
                    and citation.get('index_revision')==root.get('index_sha256',root.get('index_revision'))):return True
            pending.extend(v for v in value.values() if isinstance(v,(dict,list)))
    return False

def workflow_prompt(case: str, context: dict, skill: Path, python: Path, powershell: Path)->str:
    prefix='' if case in SELECTION_CASES else 'Use the MQL5 coding skill at '+str(skill/'SKILL.md')+'. '
    scope=' Do not launch external applications, change installed packages, publish, or ask for permission.' if case in ('selection-mql4-inventory','selection-python-repair') else ' Do not use real MetaEditor/MT5, trade, change installed packages, publish, or ask for permission. Treat synthetic executables only as workflow test doubles.'
    return prefix+'Work only in this disposable workspace. '+context['task']+scope+' Keep staged resources unchanged; use Python -B to avoid new bytecode caches. Write the required artifacts, then return the structured conclusion with case_id '+case+'. Absolute Python: '+str(python)+'. PowerShell: '+str(powershell)+'.'

def grade(case:str,root:Path,final:dict,events:list[dict],before:dict,*,receipt_verifier=None,staged_before:dict|None=None,powershell_host:Path|None=None)->list[str]:
    failures=[]
    if not isinstance(final,dict) or set(final)!=set(SCHEMA['required']) or final.get('case_id')!=case or final.get('status') not in ('completed','limited'):return ['Invalid or unsuccessful structured conclusion']
    if (not isinstance(final.get('findings'),list) or any(not isinstance(f,dict) or set(f)!= {'code','detail'} or not all(isinstance(x,str) for x in f.values()) for f in final['findings'])
        or any(not isinstance(final.get(k),list) or any(not isinstance(x,str) for x in final[k]) for k in ('evidence','limitations'))):return ['Invalid conclusion field types']
    requested_case=case;case=SELECTION_ALIASES.get(case,case)
    inputs=root/'inputs';out=root/'outputs';events,trace_problems=normalize_trace(events);failures+=trace_problems
    if powershell_host is not None:
        events,command_problems=inspected_trace_commands(events,powershell_host,root);failures+=command_problems
    if case=='standalone-source-review' and not relevant_array_documentation(events):failures.append('Missing returned relevant array documentation passage with verified citation identity')
    if staged_before is not None:failures+=staged_skill_issues(root/'.agents/skills/mql5-coding',staged_before)
    commands=[event['item']['command'] for event in events if event.get('item',{}).get('type')=='command_execution']
    if any(event.get('item',{}).get('_native_start_expression') for event in events):failures.append('Unreviewed native start expression bypasses supplied workflow')
    if not commands:failures.append('No observable command execution')
    for item in (event['item'] for event in events if event.get('item',{}).get('type')=='command_execution'):
        command=item['command']
        # Trusted AST leaf reads/writes/printing do not execute named data.
        # Nested invocations and residual start expressions are separate items.
        if item.get('_scope_data_only'):continue
        low=command.lower()
        if terminal_launch_attempt(command):failures.append('Forbidden terminal launch')
        failures+=forbidden_workflow_actions(case,root,command)
        if re.search(r'\b(?:git\s+(?:push|commit)|install-codex|uninstall-codex|update-mql5skill)\b',low):failures.append('Out-of-scope installation or publication')
    current=inventory(inputs)
    for name,digest in before.items():
        if (case=='isolated-behavior-tests' and name=='Calculation.mqh' or case=='selection-python-repair' and name=='calculation.py') and current.get(name)!=digest:
            if current.get(name)!=inventory(out).get(name):failures.append('Revised calculation source differs from the required output')
            continue
        if current.get(name)!=digest:failures.append('Input evidence changed: '+name)
    resources=selection_resources(root,events)
    if requested_case in SELECTION_ALIASES and not resources:failures.append('No observed read of selected relevant resources')
    if requested_case in ('selection-mql4-inventory','selection-python-repair'):
        if resources or any(e.get('item',{}).get('type')=='mcp_tool_call' and e.get('item',{}).get('server')=='mql5-chm' for e in events):failures.append('Unrelated platform resources used for a general task')
        if any(re.search(r'(?:mql5_toolkit|invoke-mql5|compile-mql5|invoke-mt5|read-mql5tester)',c,re.I) for c in commands):failures.append('Unrelated platform helper used for a general task')
    if requested_case in SELECTION_CASES and current.keys()!=before.keys():failures.append('Input evidence files added or removed')
    try:
        if case=='report-comparison':
            result=load(out/'comparison/result.json')
            if result['compatibility']['status']!='incompatible' or result['metrics']['net_profit']['difference']['value']!='110.19':failures.append('Incorrect report comparison')
            if result['expectations']['status']!='not_requested':failures.append('Invented expectation')
            if result['baseline']['evidence_linkage']['status']!='hash_verified' or result['candidate']['evidence_linkage']['status']!='hash_verified':failures.append('Recorded report commitments were not verified')
        elif case=='deleted-header-impact':
            result=load(out/'impact/result.json')
            if {Path(p).name for p in result['possible_affected_entrypoints']}!={'A.mq5','B.mq5'}:failures.append('Incorrect affected consumers')
            failures+=compiled_outcome(root,events,receipt_verifier,powershell_host=powershell_host)
            if not final['limitations']:failures.append('Missing synthetic/uncertain compilation limitation')
        elif case=='journal-grouping':
            result=load(out/'journal/result.json')
            if sorted(g['count'] for g in result['groups'])!=[1,2] or result['evidence_status']!='partial_segments':failures.append('Incorrect grouping or evidence completeness')
            if 'MQL5_CODING_PASS' in json.dumps(result) or 'a'*32 in json.dumps(result):failures.append('Marker plaintext exposed')
        elif case=='standalone-source-review':
            result=load(out/'review.json')
            issues=result if isinstance(result,list) else result.get('issues',result.get('findings',[result]))
            if (not isinstance(issues,list)
                or any(not isinstance(i,dict) or type(i.get('line')) is not int or i['line']<1
                    or any(not isinstance(i.get(key),str) or not i[key].strip() for key in ('code','trigger','consequence')) for i in issues)
                or not any(i['line']==5 for i in issues)):failures.append('Concrete source defect was not located/explained')
            if any('mql5_toolkit.py' in c or 'Compile-Mql5' in c for c in commands):failures.append('Unrelated processing in read-only source review')
            if not any((e.get('item') or {}).get('type')=='mcp_tool_call' and (e.get('item') or {}).get('server')=='mql5-chm' and (e.get('item') or {}).get('tool') in ('mql5_chm_search','mql5_chm_read','mql5_chm_lookup_identifiers') and (e.get('item') or {}).get('status')=='completed' and not (e.get('item') or {}).get('error') for e in events):failures.append('Missing successful platform documentation evidence')
        elif case=='scenario-validation':
            result=load(out/'validation/result.json')
            if result['action']!='Validate' or result['status']!='validated':failures.append('Scenario configuration did not validate')
            if any((inputs/'project').glob('*.ex5')) or any((inputs/'project').glob('mql5-compile-*.json')):failures.append('Validation compiled or executed')
        elif case=='profile-without-conditions':
            result=load(out/'profile/result.json')
            if result['compatibility']['status']!='insufficient_evidence' or not final['limitations']:failures.append('Missing profiler evidence was not disclosed')
            if not result['uncertain']['baseline']:failures.append('Repeated profile identities were not retained as uncertain')
        elif case=='selection-mql4-inventory':
            result=load(out/'inventory.json')
            expected=[{'path':p.relative_to(inputs).as_posix(),'extension':p.suffix,'bytes':p.stat().st_size} for p in sorted(inputs.rglob('*')) if p.is_file()]
            if not isinstance(result,dict) or set(result)!={'files'} or not isinstance(result['files'],list) or sorted(result['files'],key=lambda x:x['path'])!=sorted(expected,key=lambda x:x['path']):failures.append('Incorrect file inventory')
            if any(type(item.get('bytes')) is not int for item in result['files']):failures.append('Inventory byte sizes must be integers')
        elif case=='selection-python-repair':
            if current.get('calculation.py')!=inventory(out).get('calculation.py'):failures.append('Repaired Python input differs from output source')
            cases=load(out/'cases.json')
            if (cases!=load(inputs/'specification.json')['cases'] or not isinstance(cases,list)
                or any(not isinstance(c,dict) or set(c)!= {'n','maximum','expected'} or any(type(c[k]) is not int for k in c) for c in cases)):failures.append('Python test cases differ from independent specification')
            if not evaluate_python_calculation((out/'calculation.py').read_text(),cases):failures.append('Python calculation fails independent boundary specification')
        else:
            cases=load(out/'cases.json');cases=cases.get('cases',[]) if isinstance(cases,dict) else cases
            if (cases!=load(inputs/'specification.json')['cases'] or not isinstance(cases,list)
                or any(not isinstance(c,dict) or set(c)!= {'n','maximum','expected'} or any(type(c[k]) is not int for k in c) for c in cases)):failures.append('Test cases differ from independent specification')
            code=(out/'Calculation.mqh').read_text();test=(out/'SelfTest.mq5').read_text()
            if not evaluate_calculation(code,cases):failures.append('Calculation expression fails the independent boundary specification')
            if not evaluate_assertions(test,cases):failures.append('Missing active assertion or incorrect independently specified expected value')
            if not final['limitations']:failures.append('Missing native execution limitation')
    except (OSError,ValueError,KeyError,TypeError,AttributeError,RecursionError):failures.append('Required evidence artifact missing or invalid')
    return failures

def skill_configuration(skill,disabled):
    selected_path=str((skill/'SKILL.md').resolve())
    settings=[s for s in disabled if Path(s['path']).resolve()!=Path(selected_path)]+[{'path':selected_path,'enabled':True}]
    return '['+','.join('{path='+json.dumps(s['path'])+',enabled='+str(s['enabled']).lower()+'}' for s in settings)+']'

def skill_listing(value,work):
    if not isinstance(value,dict) or not isinstance(value.get('data'),list) or len(value['data'])!=1:raise ValueError('Invalid discovery root')
    entry=value['data'][0]
    if not isinstance(entry,dict) or not isinstance(entry.get('cwd'),str) or not Path(entry['cwd']).is_absolute() or Path(entry['cwd']).resolve()!=work.resolve() or entry.get('errors')!=[]:raise ValueError('Invalid discovery scope or errors')
    skills=entry.get('skills')
    if not isinstance(skills,list) or not 1<=len(skills)<=1024:raise ValueError('Invalid skill count')
    paths=set()
    for skill in skills:
        if not isinstance(skill,dict) or not isinstance(skill.get('name'),str) or not isinstance(skill.get('path'),str) or not isinstance(skill.get('enabled'),bool) or skill.get('scope') not in ('user','repo','system','admin'):raise ValueError('Invalid skill metadata')
        path=Path(skill['path'])
        if not path.is_absolute() or path.name!='SKILL.md' or path.resolve() in paths:raise ValueError('Invalid or duplicate skill path')
        paths.add(path.resolve())
    return skills

def resolve_skill_isolation(args,work,skill,root,execution_env,deadline=None):
    """Query actual repo/user/admin/bundled discovery, then verify one enabled skill."""
    root.mkdir()
    proof={'schema_version':1,'operation':'codex_skill_isolation','status':'failed','issues':[],'probes':[]}
    disabled=[]
    try:
        for label,settings in (('discovered',None),('isolated','pending')):
            stdout=root/(label+'.json');stderr=root/(label+'.stderr.txt')
            cli=[str(args.codex_path)]
            if settings is not None:cli+=['-c','skills.config='+skill_configuration(skill,disabled)]
            cli+=['app-server','--listen','stdio://']
            command=[str(args.python),str(REPO/'tests/workflow_skill_discovery.py'),str(work),*cli]
            seconds=40
            if deadline is not None:
                remaining=deadline-time.monotonic()
                if remaining<=0:raise RuntimeError('Discovery setup deadline exhausted')
                seconds=max(1,min(seconds,int(remaining)))
            measurement=run_owned(command,work,stdout,stderr,env=execution_env,seconds=seconds)
            proof['probes'].append({'kind':label,'measurement':measurement,'response_sha256':sha(stdout) if stdout.is_file() else None})
            if measurement['status']!='completed' or measurement['exit_code']!=0 or not measurement['cleanup_verified'] or measurement['console_bytes']>4194304:raise RuntimeError('Discovery execution or cleanup failed')
            listing=skill_listing(load(stdout),work)
            if settings is None:
                disabled=[{'path':str(Path(s['path']).resolve()),'enabled':False} for s in listing if Path(s['path']).resolve()!=(skill/'SKILL.md').resolve()]
                proof['disabled']=disabled
            else:
                enabled=[s for s in listing if s['enabled']]
                if len(enabled)!=1 or enabled[0]['name']!='mql5-coding' or Path(enabled[0]['path']).resolve()!=(skill/'SKILL.md').resolve():raise RuntimeError('Unexpected enabled skill')
                proof['enabled']=[{'name':s['name'],'path':s['path'],'scope':s['scope']} for s in enabled]
        proof['status']='passed'
    except (OSError,RuntimeError,ValueError,TypeError,KeyError,RecursionError):
        proof['issues'].append('Actual CLI skill discovery or owned cleanup failed; scored tasks must not run.')
    save(root/'result.json',proof)
    return disabled,proof

def unselected_skill_reads(events,disabled):
    paths=[str(Path(s['path']).resolve()).replace('\\','/').lower() for s in disabled]
    for event in normalize_trace(events)[0]:
        command=event.get('item',{}).get('command')
        if isinstance(command,str):
            normalized=command.replace('\\\\','\\').replace('\\','/').lower()
            if any(path in normalized for path in paths):return True
    return False

def codex_command(args,work,skill,disabled,schema,final,prompt,model,effort):
    selected=skill_configuration(skill,disabled)
    return [str(args.codex_path),'-a','never','-c','skills.config='+selected,'-c','model_reasoning_effort='+json.dumps(effort),'-c','web_search="disabled"','-c','windows.sandbox="unelevated"','-c','shell_environment_policy.ignore_default_excludes=false','-c','mcp_servers.mql5-chm.command='+json.dumps(str(args.mcp_package_root/'runtime/node.exe')),'-c','mcp_servers.mql5-chm.args='+json.dumps([str(args.mcp_package_root/'app/server.mjs')]),'exec','--ignore-user-config','--ignore-rules','--ephemeral','--sandbox','workspace-write','--skip-git-repo-check','--json','--model',model,'-C',str(work),'--output-schema',str(schema),'-o',str(final),prompt]

def shared_setup_failure(events,measurement):
    """Stop shared client failures, rather than repeating them across all cases."""
    if not measurement.get('cleanup_verified'):return 'Owned-process cleanup is unverified'
    if measurement.get('status')=='launch_failed':return 'CLI process launch failed'
    normalized,issues=normalize_trace(events)
    errors=[e for e in normalized if e.get('type') in ('error','turn.failed') or e.get('item',{}).get('type')=='error']
    text=' '.join(json.dumps(e,ensure_ascii=False) for e in errors).lower()
    if re.search(r'usage[ _-]limit|rate[ _-]limit|insufficient[ _-](?:quota|credits)|quota[ _-]exceeded|credits[ _-](?:exhausted|depleted)',text):return 'Shared account usage, quota or rate limit reached'
    if re.search(r'requires a newer version|unsupported model|model[^\n]{0,100}(?:not supported|not available)|invalid api key|unauthorized|authentication|sandbox[^\n]{0,100}(?:unavailable|failed)|mcp[^\n]{0,100}(?:startup|initialize)[^\n]{0,50}fail',text):return 'Shared authentication, model, sandbox or MCP setup failed'
    if errors and not trace_summary(normalized)['commands']:return 'CLI failed before agent commands; shared setup must be checked'
    return None

def grade_preflight(work,final,events,measurement,probe,expected_mcp):
    errors=[]
    normalized,trace_errors=normalize_trace(events);errors+=trace_errors
    if measurement.get('status')!='completed' or measurement.get('exit_code')!=0 or not measurement.get('cleanup_verified'):errors.append('Preflight execution or cleanup failed')
    if measurement.get('console_bytes',0)>16777216:errors.append('Preflight output exceeded the supported limit')
    if trace_summary(normalized)['execution_error']:errors.append('Preflight trace contains an execution error')
    valid=isinstance(final,dict) and set(final)==set(SCHEMA['required'])
    if valid:
        valid=final['case_id']=='setup-preflight' and final['status']=='completed' and isinstance(final['findings'],list)
        valid=valid and all(isinstance(f,dict) and set(f)=={'code','detail'} and all(isinstance(v,str) for v in f.values()) for f in final['findings'])
        valid=valid and all(isinstance(final[k],list) and all(isinstance(v,str) for v in final[k]) for k in ('evidence','limitations'))
    if not valid:errors.append('Preflight structured conclusion is unavailable or invalid')
    try:
        if load(work/'outputs/preflight.json')!={'probe':probe}:raise ValueError('Wrong sandbox output')
        if (work/'inputs/preflight.txt').read_text(encoding='utf-8')!=probe:raise ValueError('Changed sandbox input')
    except (OSError,ValueError,TypeError,RecursionError):errors.append('Sandbox read/write evidence is missing, changed or invalid')
    matched=False
    for event in normalized:
        item=event.get('item',{})
        if event.get('type')!='item.completed' or item.get('type')!='mcp_tool_call' or item.get('server')!='mql5-chm' or item.get('tool')!='mql5_chm_status' or item.get('status')!='completed' or item.get('error'):continue
        result=item.get('result',{})
        if not isinstance(result,dict) or result.get('isError') is True:continue
        content=result.get('structured_content',result.get('structuredContent'))
        if not isinstance(content,dict):
            try:content=json.loads(next(c['text'] for c in result.get('content',[]) if isinstance(c,dict) and c.get('type')=='text'))
            except (ValueError,KeyError,TypeError,StopIteration,RecursionError):continue
        if isinstance(content,dict) and all(content.get(k)==v for k,v in expected_mcp.items()):matched=True
    if not matched:errors.append('Preflight lacks a returned matching MCP status')
    for event in normalized:
        command=event.get('item',{}).get('command')
        if isinstance(command,str) and forbidden_workflow_actions('scenario-validation',work,command):errors.append('Preflight attempted forbidden platform execution')
    return errors

def run_preflight(args,result,disabled,execution_env,model,effort):
    deadline=time.monotonic()+min(args.timeout_seconds,180)
    root=args.output/'preflight';root.mkdir();work=root/'workspace';work.mkdir()
    skill=work/'.agents/skills/mql5-coding';shutil.copytree(args.skill_root,skill)
    before=inventory(skill);probe=secrets.token_hex(16)
    (work/'inputs').mkdir();(work/'outputs').mkdir();(work/'inputs/preflight.txt').write_text(probe,encoding='utf-8')
    prompt='Setup preflight only. Read inputs/preflight.txt and write outputs/preflight.json with exactly one string property probe containing the file text. Call mql5_chm_status and inspect its returned status. Do not compile, run MT5, trade, publish, or edit the selected skill. Return the required structured conclusion with case_id setup-preflight, status completed, evidence [outputs/preflight.json], and concise findings/limitations. Use only the selected MCP. This is not a scored evaluation case.'
    temporary=work/'.temp';temporary.mkdir()
    disabled,isolation=resolve_skill_isolation(args,work,skill,root/'skill-discovery',execution_env,deadline=deadline)
    remaining=int(deadline-time.monotonic())
    if remaining<=0:isolation['issues'].append('Setup deadline exhausted before model execution')
    if isolation['status']!='passed' or remaining<=0:
        proof={'schema_version':1,'operation':'codex_setup_preflight','status':'failed','issues':isolation['issues'],'measurement':{'status':'launch_failed','exit_code':None,'cleanup_verified':all(p['measurement'].get('cleanup_verified',False) for p in isolation['probes']) if isolation['probes'] else False},'trace_sha256':None,'skill_discovery':str(root/'skill-discovery/result.json')}
        save(root/'result.json',proof);result['preflight']=proof;save(args.output/'progress.json',result)
        print('setup-preflight: failed',flush=True);return False
    command=codex_command(args,work,skill,disabled,args.output/'response.schema.json',root/'final.json',prompt,model,effort)
    try:measurement=run_owned(command,work,root/'trace.jsonl',root/'stderr.txt',env={**execution_env,'TEMP':str(temporary),'TMP':str(temporary)},seconds=remaining)
    except (OSError,RuntimeError):
        measurement={'status':'launch_failed','exit_code':None,'cleanup_verified':False,'elapsed_seconds':None,'console_bytes':sum(p.stat().st_size for p in (root/'trace.jsonl',root/'stderr.txt') if p.is_file())}
    try:
        if measurement['console_bytes']>16777216:events,errors=[],['Oversized preflight trace retained without parsing']
        else:events,errors=read_trace(root/'trace.jsonl')
    except (OSError,UnicodeError):events,errors=[],['Preflight trace unavailable or invalid']
    try:final=load(root/'final.json')
    except (OSError,ValueError,RecursionError):final=None
    errors+=grade_preflight(work,final,events,measurement,probe,{'corpus_revision':result['mcp']['corpus_revision'],'index_sha256':result['mcp']['index_revision']})
    errors+=staged_skill_issues(skill,before)
    if unselected_skill_reads(events,disabled):errors.append('Preflight referenced an unselected skill')
    proof={'schema_version':1,'operation':'codex_setup_preflight','status':'passed' if not errors else 'failed','issues':errors,'measurement':measurement,'model':model,'reasoning_effort':effort,'codex_version':result['codex_version'],'codex_sha256':result['codex_sha256'],'trace_sha256':sha(root/'trace.jsonl') if (root/'trace.jsonl').is_file() else None,'selected_skill_before':before,'selected_skill_after':inventory(skill)}
    proof['skill_discovery']={'path':str(root/'skill-discovery/result.json'),'sha256':sha(root/'skill-discovery/result.json')}
    save(root/'result.json',proof);result['preflight']={k:v for k,v in proof.items() if k not in ('selected_skill_before','selected_skill_after')};save(args.output/'progress.json',result)
    print('setup-preflight: '+proof['status'],flush=True)
    return not errors

def main(argv=None)->int:
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('skill-root','baseline-skill-root','mcp-package-root','codex-path','powershell','output'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--python',type=Path,default=Path(sys.executable));p.add_argument('--repetitions',type=int,choices=(1,3,5),default=3);p.add_argument('--case',choices=CASES+SELECTION_CASES,action='append');p.add_argument('--model',required=True,help='Exact model identifier selected for the active request; no saved-default fallback');p.add_argument('--reasoning-effort',required=True,help='Reasoning setting selected for the active request');p.add_argument('--timeout-seconds',type=int,default=600)
    p.add_argument('--include-selection-cases',action='store_true',help='Add four implicit selection cases to the seven default cases')
    p.add_argument('--preflight-only',action='store_true',help='Check live CLI, sandbox and MCP setup without running scored cases')
    args=p.parse_args(argv)
    for path in (args.skill_root,args.baseline_skill_root,args.mcp_package_root,args.codex_path,args.powershell,args.output,args.python):
        if not path.is_absolute():p.error('Every path must be absolute')
    if args.output.exists():p.error('Select a new output directory')
    if args.timeout_seconds<1 or args.timeout_seconds>600:p.error('Deadline must be between 1 and 600 seconds')
    model=args.model;effort=args.reasoning_effort
    if any(not value or any(character.isspace() for character in value) for value in (model,effort)):p.error('Pass the active request model identifier and reasoning setting without whitespace; saved defaults are not used')
    version=subprocess.check_output([str(args.codex_path),'--version'],text=True,timeout=10).strip()
    if not re.fullmatch(r'codex-cli \d+\.\d+\.\d+(?:[-+][A-Za-z0-9.]+)?',version):p.error('Unrecognized supported Codex CLI version response')
    help_text=subprocess.check_output([str(args.codex_path),'exec','--help'],text=True,timeout=10)
    if not all(flag in help_text for flag in ('--ignore-user-config','--ephemeral','--json','--output-schema','--output-last-message','--sandbox')):p.error('CLI lacks required evaluation interfaces')
    args.output.mkdir();save(args.output/'response.schema.json',SCHEMA)
    result={'schema_version':1,'operation':'codex_workflow_evaluation','status':'running','model':model,'reasoning_effort':effort,'codex_version':version,'codex_sha256':sha(args.codex_path),'repetitions':args.repetitions,'runs':[],'candidate_passed':False,'limitations':['Synthetic compiler/tester execution does not establish native MQL5 behavior','Repeated task observations do not prove universal time/token improvement']}
    originals={str(root):inventory(root) for root in (args.skill_root,args.baseline_skill_root)}
    result['skills']={arm:{'version':load(root/'version.json')['version'],'source_commit':source_commit(root),'files':originals[str(root)]} for arm,root in (('baseline',args.baseline_skill_root),('candidate',args.skill_root))}
    result['mcp']={'version':load(args.mcp_package_root/'package.json')['version'],'server_sha256':sha(args.mcp_package_root/'app/server.mjs'),'node_sha256':sha(args.mcp_package_root/'runtime/node.exe'),'package_checksums_sha256':sha(args.mcp_package_root/'checksums.sha256')}
    active=load(args.mcp_package_root/'data/active.json');revision=active['active_revision'];manifest=load(args.mcp_package_root/'revisions'/revision/'manifest.json')
    result['mcp'].update({'index_revision':revision,'corpus_revision':manifest['corpus_revision'],'database_sha256':sha(args.mcp_package_root/'revisions'/revision/'mql5-docs.sqlite')})
    binaries=args.output/'synthetic-executables';binaries.mkdir()
    csc=Path(os.environ['WINDIR'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    metadata=binaries/'metadata.cs';metadata.write_text('using System.Reflection;[assembly:AssemblyFileVersion("5.0.0.1234")]',encoding='utf-8')
    subprocess.run([str(csc),'/nologo','/target:exe','/out:'+str(binaries/'metaeditor64.exe'),str(REPO/'tests/FakeMetaEditor.cs')],capture_output=True,check=True)
    subprocess.run([str(csc),'/nologo','/target:exe','/out:'+str(binaries/'terminal64.exe'),str(REPO/'tests/FakeTerminal.cs'),str(metadata)],capture_output=True,check=True)
    result['synthetic_executable_sha256']=inventory(binaries)
    result['powershell']={'path':str(args.powershell.resolve()),'sha256':sha(args.powershell)}
    result['evaluator_sha256']={p.name:sha(p) for p in (Path(__file__),Path(__file__).with_name('workflow_process.py'),REPO/'tests/workflow_skill_discovery.py',REPO/'tests/Verify-WorkflowReceipts.ps1',REPO/'tests/Inspect-WorkflowCommands.ps1',REPO/'tests/evaluation-cases.json',REPO/'tests/selection-cases.json')}
    disabled=[]
    # Credentials stay in an ephemeral, job-local home outside fixtures and evidence.
    # Desktop IPC/originator variables would expose unrelated app tools and policy.
    auth_parent=Path.home()/'.codex-workflow-auth'
    auth_parent.mkdir(exist_ok=True)
    credentials=tempfile.TemporaryDirectory(prefix='job-',dir=auth_parent)
    atexit.register(credentials.cleanup)
    private_home=Path(credentials.name)
    authentication_home=Path(os.environ.get('CODEX_HOME',Path.home()/'.codex'))
    auth=authentication_home/'auth.json'
    if auth.is_file():shutil.copy2(auth,private_home/'auth.json')
    execution_env={k:v for k,v in os.environ.items() if not k.startswith('CODEX_') and k not in ('METATRADER_MCP_API_KEY',)}
    execution_env['CODEX_HOME']=str(private_home)
    # Prevent ordinary toolkit imports from changing either selected staged tree.
    # This is inherited only by evaluation children, never set globally.
    execution_env['PYTHONDONTWRITEBYTECODE']='1'
    if not run_preflight(args,result,disabled,execution_env,model,effort):
        result['status']='failed';save(args.output/'evaluation.json',result);credentials.cleanup();return 2
    if args.preflight_only:
        result['status']='preflight_passed';save(args.output/'evaluation.json',result);credentials.cleanup();return 0
    for case in args.case or (CASES+SELECTION_CASES if args.include_selection_cases else CASES):
        for arm,source in (('baseline',args.baseline_skill_root),('candidate',args.skill_root)):
            for repetition in range(1,args.repetitions+1):
                runroot=args.output/(case+'-'+arm+'-'+str(repetition));runroot.mkdir();work=runroot/'workspace';work.mkdir();skill=work/'.agents/skills/mql5-coding';shutil.copytree(source,skill)
                context=prepare(case,work,skill,args.powershell,args.python,binaries)
                staged_before=inventory(skill);save(runroot/'selected-skill-before.json',staged_before)
                prompt=workflow_prompt(case,context,skill,args.python,args.powershell)
                (runroot/'prompt.txt').write_text(prompt,encoding='utf-8');save(runroot/'input-hashes.json',context['input_hashes'])
                temporary=work/'.temp';temporary.mkdir()
                run_env={**execution_env,'TEMP':str(temporary),'TMP':str(temporary)}
                disabled,isolation=resolve_skill_isolation(args,work,skill,runroot/'skill-discovery',run_env)
                if isolation['status']!='passed':
                    result['status']='aborted';result['abort_reason']='Actual skill discovery or cleanup failed before a scored task';save(args.output/'evaluation.json',result);credentials.cleanup();return 2
                command=codex_command(args,work,skill,disabled,args.output/'response.schema.json',runroot/'final.json',prompt,model,effort)
                started=time.time();measurement=run_owned(command,work,runroot/'trace.jsonl',runroot/'stderr.txt',env=run_env,seconds=args.timeout_seconds)
                try:
                    if measurement['console_bytes']>16777216:events,errors=[],['Trace output exceeded the supported byte limit; retained evidence was not parsed']
                    else:events,errors=read_trace(runroot/'trace.jsonl')
                except (OSError,UnicodeError):events,errors=[],['Trace unavailable or invalid encoding']
                try:final=load(runroot/'final.json')
                except (OSError,ValueError,RecursionError):final=None;errors.append('Final output unavailable or malformed')
                errors+=grade(case,work,final,events,context['input_hashes'],receipt_verifier=lambda paths:verify_workflow_receipts(args.powershell,args.skill_root,work,paths,runroot/'receipt-verification.json'),staged_before=staged_before,powershell_host=args.powershell)
                unexpected_skill=unselected_skill_reads(events,disabled)
                if unexpected_skill:errors.append('Task referenced an unselected skill; isolation failed')
                staged_after=inventory(skill);save(runroot/'selected-skill-after.json',staged_after)
                trace=trace_summary(events);errors+=trace['issues']
                if trace['execution_error']:errors.append('CLI trace contains an execution/model error; no fallback or silent retry is accepted')
                if measurement['status']!='completed' or measurement['exit_code']!=0 or not measurement['cleanup_verified']:errors.append('CLI execution incomplete, failed, or cleanup unverified')
                usage=trace['usage'];commands=trace['commands'];command_text=[c['command'] for c in commands]
                item={'case':case,'arm':arm,'repetition':repetition,'status':'passed' if not errors else 'failed','issues':errors,'selected_skill':{'before_sha256':sha(runroot/'selected-skill-before.json'),'after_sha256':sha(runroot/'selected-skill-after.json'),'issues':staged_skill_issues(skill,staged_before,staged_after)},'measurement':{**measurement,'commands':len(commands),'repeated_identical_commands':len(command_text)-len(set(command_text)),'runner_retries':0,'agent_retries':None,'retry_count_reason':'Semantic agent retries are not a stable trace metric; repeated identical completed commands are recorded separately','token_usage':usage,'token_usage_reason':None if usage else 'Usage unavailable in the emitted CLI trace','artifact_bytes':sum(p.stat().st_size for p in work.rglob('*') if p.is_file())},'trace':str(runroot/'trace.jsonl'),'trace_sha256':sha(runroot/'trace.jsonl'),'started_unix_seconds':started}
                item['skill_discovery']={'path':str(runroot/'skill-discovery/result.json'),'sha256':sha(runroot/'skill-discovery/result.json')}
                if case in ('standalone-source-review','selection-mql5-review'):
                    item['grading_scope']={'automatic':'Required typed artifact fields, known defect line and returned matching documentation/resource evidence.',
                                           'prose_semantics':'not_independently_graded; review the explanation before claiming source-review correctness'}
                result['runs'].append(item);save(runroot/'score.json',item);save(args.output/'progress.json',result);print(case+' '+arm+' '+str(repetition)+': '+item['status'],flush=True)
                shared_failure='Unselected skill referenced; shared isolation failed' if unexpected_skill else shared_setup_failure(events,measurement)
                if shared_failure:
                    result['status']='aborted';result['abort_reason']=shared_failure;save(args.output/'evaluation.json',result);credentials.cleanup();return 2
    for source,previous in originals.items():
        if inventory(Path(source))!=previous:raise RuntimeError('Evaluation changed an original skill tree')
    candidates=[r for r in result['runs'] if r['arm']=='candidate'];result['candidate_passed']=bool(candidates) and all(r['status']=='passed' for r in candidates);result['status']='passed' if result['candidate_passed'] else 'failed';save(args.output/'evaluation.json',result)
    credentials.cleanup()
    return 0 if result['candidate_passed'] else 1

if __name__=='__main__':sys.exit(main())
