"""Execute and independently score the seven Codex skill workflows on Windows."""
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
import tomllib
import atexit
import tempfile
from workflow_process import run_owned

REPO=Path(__file__).resolve().parents[1]
CASES=tuple(c['id'] for c in json.loads((REPO/'tests/evaluation-cases.json').read_text())['cases'])
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
    return subprocess.run([str(host),'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',base64.b64encode(command.encode('utf-16le')).decode()],capture_output=True,timeout=90,cwd=cwd)

def prepare(case:str,root:Path,skill:Path,host:Path,python:Path,binaries:Path)->dict:
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
            context['task']='A shared header was removed after the saved inputs/before inventory. Inventory the current project, save an include comparison under outputs/impact, identify possible affected entrypoints, and compile the affected entrypoints through the supplied project profile. Invoke Invoke-Mql5Project.ps1 with literal -ProfilePath "'+str(profile)+'" and literal -Action Compile; retain its MQL5_COMPILE_RECEIPT output and source/EX5/log evidence. The executables in synthetic-install are test doubles: this checks workflow execution, not native MQL5 compilation. Report unresolved dependencies and that validation limit.'
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
    else:
        save(inputs/'specification.json',{'function':'ClampCount','contract':'For integer n and integer maximum>=0, return min(max(n,0),maximum).','cases':[{'n':-2,'maximum':3,'expected':0},{'n':0,'maximum':3,'expected':0},{'n':2,'maximum':3,'expected':2},{'n':3,'maximum':3,'expected':3},{'n':4,'maximum':3,'expected':3},{'n':2,'maximum':0,'expected':0}]})
        (inputs/'Calculation.mqh').write_text('int ClampCount(int n,int maximum){ return MathMin(n,maximum); }\n')
        context['task']='Fix the isolated ClampCount calculation to satisfy inputs/specification.json, using only its definition and a single return expression with MathMin/MathMax for this bounded evaluation. Copy the revised include to outputs/Calculation.mqh. Prepare outputs/SelfTest.mq5 with #include "Calculation.mqh" and void OnStart() containing exactly six sequential assertions of the form if (ClampCount(n,maximum) != expected) Print("FAIL:case label");, substituting the independently specified integers for each case. Comments and #property strict are allowed; do not put assertions behind other control flow. Save outputs/cases.json with independently specified input/expected cases from the specification. No native compiler or tester is available for this case. Explain exactly which behavior is specified and which execution remains unverified.'
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
        if isinstance(node,ast.Constant) and type(node.value) is int:return node.value
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

def grade(case:str,root:Path,final:dict,events:list[dict],before:dict,*,receipt_verifier=None,staged_before:dict|None=None,powershell_host:Path|None=None)->list[str]:
    failures=[]
    if not isinstance(final,dict) or set(final)!=set(SCHEMA['required']) or final.get('case_id')!=case or final.get('status') not in ('completed','limited'):return ['Invalid or unsuccessful structured conclusion']
    if (not isinstance(final.get('findings'),list) or any(not isinstance(f,dict) or set(f)!= {'code','detail'} or not all(isinstance(x,str) for x in f.values()) for f in final['findings'])
        or any(not isinstance(final.get(k),list) or any(not isinstance(x,str) for x in final[k]) for k in ('evidence','limitations'))):return ['Invalid conclusion field types']
    inputs=root/'inputs';out=root/'outputs';events,trace_problems=normalize_trace(events);failures+=trace_problems
    if staged_before is not None:failures+=staged_skill_issues(root/'.agents/skills/mql5-coding',staged_before)
    commands=[event['item']['command'] for event in events if event.get('item',{}).get('type')=='command_execution']
    if not commands:failures.append('No observable command execution')
    for command in commands:
        low=command.lower()
        if terminal_launch_attempt(command):failures.append('Forbidden terminal launch')
        failures+=forbidden_workflow_actions(case,root,command)
        if re.search(r'\b(?:git\s+(?:push|commit)|install-codex|uninstall-codex|update-mql5skill)\b',low):failures.append('Out-of-scope installation or publication')
    current=inventory(inputs)
    for name,digest in before.items():
        if case=='isolated-behavior-tests' and name=='Calculation.mqh' and current.get(name)!=digest:
            if current.get(name)!=inventory(out).get(name):failures.append('Revised calculation source differs from the required output')
            continue
        if current.get(name)!=digest:failures.append('Input evidence changed: '+name)
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
            if not any(i.get('line')==5 and i.get('trigger') and i.get('consequence') for i in issues):failures.append('Concrete source defect was not located/explained')
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

def main(argv=None)->int:
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('skill-root','baseline-skill-root','mcp-package-root','codex-path','powershell','output'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--python',type=Path,default=Path(sys.executable));p.add_argument('--repetitions',type=int,choices=(1,3,5),default=3);p.add_argument('--case',choices=CASES,action='append');p.add_argument('--model');p.add_argument('--reasoning-effort');p.add_argument('--timeout-seconds',type=int,default=600)
    args=p.parse_args(argv)
    for path in (args.skill_root,args.baseline_skill_root,args.mcp_package_root,args.codex_path,args.powershell,args.output,args.python):
        if not path.is_absolute():p.error('Every path must be absolute')
    if args.output.exists():p.error('Select a new output directory')
    if args.timeout_seconds<1 or args.timeout_seconds>600:p.error('Deadline must be between 1 and 600 seconds')
    home=Path(os.environ.get('CODEX_HOME',Path.home()/'.codex'));config=tomllib.loads((home/'config.toml').read_text()) if (home/'config.toml').exists() else {}
    model=args.model or config.get('model');effort=args.reasoning_effort or config.get('model_reasoning_effort')
    if not model or not effort:p.error('Select explicit model and reasoning effort when no configured values exist')
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
    result['evaluator_sha256']={p.name:sha(p) for p in (Path(__file__),Path(__file__).with_name('workflow_process.py'),REPO/'tests/Verify-WorkflowReceipts.ps1',REPO/'tests/evaluation-cases.json')}
    disabled=[{'path':str(path.parent),'enabled':False} for path in (home/'skills').rglob('SKILL.md')]
    # Credentials stay in an ephemeral, job-local home outside fixtures and evidence.
    # Desktop IPC/originator variables would expose unrelated app tools and policy.
    auth_parent=Path.home()/'.codex-workflow-auth'
    auth_parent.mkdir(exist_ok=True)
    credentials=tempfile.TemporaryDirectory(prefix='job-',dir=auth_parent)
    atexit.register(credentials.cleanup)
    private_home=Path(credentials.name)
    auth=home/'auth.json'
    if auth.is_file():shutil.copy2(auth,private_home/'auth.json')
    execution_env={k:v for k,v in os.environ.items() if not k.startswith('CODEX_') and k not in ('METATRADER_MCP_API_KEY',)}
    execution_env['CODEX_HOME']=str(private_home)
    # Prevent ordinary toolkit imports from changing either selected staged tree.
    # This is inherited only by evaluation children, never set globally.
    execution_env['PYTHONDONTWRITEBYTECODE']='1'
    for case in args.case or CASES:
        for arm,source in (('baseline',args.baseline_skill_root),('candidate',args.skill_root)):
            for repetition in range(1,args.repetitions+1):
                runroot=args.output/(case+'-'+arm+'-'+str(repetition));runroot.mkdir();work=runroot/'workspace';work.mkdir();skill=work/'.agents/skills/mql5-coding';shutil.copytree(source,skill)
                context=prepare(case,work,skill,args.powershell,args.python,binaries)
                staged_before=inventory(skill);save(runroot/'selected-skill-before.json',staged_before)
                prompt='Use the MQL5 coding skill at '+str(skill/'SKILL.md')+'. Work only in this disposable workspace. '+context['task']+' Do not use real MetaEditor/MT5, trade, change installed packages, publish, or ask for permission. Keep the selected staged skill files unchanged; use Python -B for toolkit commands to avoid new bytecode caches. Treat synthetic executables only as workflow test doubles. Write the required artifacts, then return the structured conclusion with case_id '+case+'. Absolute Python: '+str(args.python)+'. PowerShell: '+str(args.powershell)+'.'
                (runroot/'prompt.txt').write_text(prompt,encoding='utf-8');save(runroot/'input-hashes.json',context['input_hashes'])
                settings=disabled+[{'path':str(skill),'enabled':True}]
                settings_toml='['+','.join('{path='+json.dumps(s['path'])+',enabled='+str(s['enabled']).lower()+'}' for s in settings)+']'
                command=[str(args.codex_path),'-a','never','-c','skills.config='+settings_toml,'-c','model_reasoning_effort='+json.dumps(effort),'-c','web_search="disabled"','-c','windows.sandbox="unelevated"','-c','shell_environment_policy.ignore_default_excludes=false','-c','mcp_servers.mql5-chm.command='+json.dumps(str(args.mcp_package_root/'runtime/node.exe')),'-c','mcp_servers.mql5-chm.args='+json.dumps([str(args.mcp_package_root/'app/server.mjs')]),'exec','--ignore-user-config','--ignore-rules','--ephemeral','--sandbox','workspace-write','--skip-git-repo-check','--json','--model',model,'-C',str(work),'--output-schema',str(args.output/'response.schema.json'),'-o',str(runroot/'final.json'),prompt]
                temporary=work/'.temp';temporary.mkdir()
                run_env={**execution_env,'TEMP':str(temporary),'TMP':str(temporary)}
                started=time.time();measurement=run_owned(command,work,runroot/'trace.jsonl',runroot/'stderr.txt',env=run_env,seconds=args.timeout_seconds)
                try:
                    if measurement['console_bytes']>16777216:events,errors=[],['Trace output exceeded the supported byte limit; retained evidence was not parsed']
                    else:events,errors=read_trace(runroot/'trace.jsonl')
                except (OSError,UnicodeError):events,errors=[],['Trace unavailable or invalid encoding']
                try:final=load(runroot/'final.json')
                except (OSError,ValueError,RecursionError):final=None;errors.append('Final output unavailable or malformed')
                errors+=grade(case,work,final,events,context['input_hashes'],receipt_verifier=lambda paths:verify_workflow_receipts(args.powershell,args.skill_root,work,paths,runroot/'receipt-verification.json'),staged_before=staged_before,powershell_host=args.powershell)
                staged_after=inventory(skill);save(runroot/'selected-skill-after.json',staged_after)
                trace=trace_summary(events);errors+=trace['issues']
                if trace['execution_error']:errors.append('CLI trace contains an execution/model error; no fallback or silent retry is accepted')
                if measurement['status']!='completed' or measurement['exit_code']!=0 or not measurement['cleanup_verified']:errors.append('CLI execution incomplete, failed, or cleanup unverified')
                usage=trace['usage'];commands=trace['commands'];command_text=[c['command'] for c in commands]
                item={'case':case,'arm':arm,'repetition':repetition,'status':'passed' if not errors else 'failed','issues':errors,'selected_skill':{'before_sha256':sha(runroot/'selected-skill-before.json'),'after_sha256':sha(runroot/'selected-skill-after.json'),'issues':staged_skill_issues(skill,staged_before,staged_after)},'measurement':{**measurement,'commands':len(commands),'repeated_identical_commands':len(command_text)-len(set(command_text)),'runner_retries':0,'agent_retries':None,'retry_count_reason':'Semantic agent retries are not a stable trace metric; repeated identical completed commands are recorded separately','token_usage':usage,'token_usage_reason':None if usage else 'Usage unavailable in the emitted CLI trace','artifact_bytes':sum(p.stat().st_size for p in work.rglob('*') if p.is_file())},'trace':str(runroot/'trace.jsonl'),'trace_sha256':sha(runroot/'trace.jsonl'),'started_unix_seconds':started}
                result['runs'].append(item);save(runroot/'score.json',item);save(args.output/'progress.json',result);print(case+' '+arm+' '+str(repetition)+': '+item['status'],flush=True)
                if not measurement['cleanup_verified']:result['status']='aborted';save(args.output/'evaluation.json',result);return 2
    for source,previous in originals.items():
        if inventory(Path(source))!=previous:raise RuntimeError('Evaluation changed an original skill tree')
    candidates=[r for r in result['runs'] if r['arm']=='candidate'];result['candidate_passed']=bool(candidates) and all(r['status']=='passed' for r in candidates);result['status']='passed' if result['candidate_passed'] else 'failed';save(args.output/'evaluation.json',result)
    credentials.cleanup()
    return 0 if result['candidate_passed'] else 1

if __name__=='__main__':sys.exit(main())
