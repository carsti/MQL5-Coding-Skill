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
            context['task']='A shared header was removed after the saved inputs/before inventory. Inventory the current project, save an include comparison under outputs/impact, identify possible affected entrypoints, and compile the affected entrypoints through the supplied project profile. The executables in synthetic-install are test doubles: this checks workflow execution, not native MQL5 compilation. Report unresolved dependencies and that validation limit.'
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
        context['task']='Fix the isolated ClampCount calculation to satisfy inputs/specification.json, using a single return expression with MathMin/MathMax for this bounded evaluation. Copy the revised include to outputs/Calculation.mqh, prepare a nontrading MQL5 assertion test in outputs/SelfTest.mq5 that exercises all six cases, and save outputs/cases.json with independently specified input/expected cases from the specification. No native compiler or tester is available for this case. Explain exactly which behavior is specified and which execution remains unverified.'
    context['input_hashes']=inventory(inputs)
    return context

def read_trace(path:Path)->tuple[list[dict],list[str]]:
    events=[];problems=[]
    for number,line in enumerate(path.read_text(encoding='utf-8-sig',errors='strict').splitlines(),1):
        if not line.strip():continue
        try:value=json.loads(line)
        except ValueError:problems.append('Malformed JSONL event '+str(number));continue
        if not isinstance(value,dict):problems.append('Non-object trace event '+str(number));continue
        events.append(value)
    return events,problems

def evaluate_calculation(code:str,cases:list[dict])->bool:
    """Interpret only the specified integer expression; this is not an MQL5 runtime."""
    body=re.search(r'int\s+ClampCount\s*\(\s*int\s+n\s*,\s*int\s+maximum\s*\)\s*\{\s*return\s+([^;]+);\s*\}',code)
    if not body:return False
    try:tree=ast.parse(body[1],mode='eval')
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

def grade(case:str,root:Path,final:dict,events:list[dict],before:dict)->list[str]:
    failures=[]
    if not isinstance(final,dict) or set(final)!=set(SCHEMA['required']) or final.get('case_id')!=case or final.get('status') not in ('completed','limited'):return ['Invalid or unsuccessful structured conclusion']
    if (not isinstance(final.get('findings'),list) or any(not isinstance(f,dict) or set(f)!= {'code','detail'} or not all(isinstance(x,str) for x in f.values()) for f in final['findings'])
        or any(not isinstance(final.get(k),list) or any(not isinstance(x,str) for x in final[k]) for k in ('evidence','limitations'))):return ['Invalid conclusion field types']
    inputs=root/'inputs';out=root/'outputs';commands=[]
    for event in events:
        item=event.get('item') or {}
        if not isinstance(item,dict):
            failures.append('Malformed trace item');continue
        if item.get('type')=='command_execution':commands.append(item.get('command',''))
    if not commands:failures.append('No observable command execution')
    for command in commands:
        low=command.lower()
        if ('terminal64.exe' in low or 'terminal.exe' in low) and not any(x in low for x in ('get-content','get-item','readall','profile','validate','metadata')):failures.append('Forbidden terminal launch')
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
            receipts=[load(p) for p in (inputs/'project').glob('mql5-compile-*.json') if not p.name.endswith('.sources.json')]
            if {Path(r['source']['path']).name for r in receipts if r.get('status')=='success'}!={'A.mq5','B.mq5'}:failures.append('Affected entrypoints were not compiled')
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
            if cases!=load(inputs/'specification.json')['cases']:failures.append('Test cases differ from independent specification')
            code=(out/'Calculation.mqh').read_text();test=(out/'SelfTest.mq5').read_text()
            if not evaluate_calculation(code,cases):failures.append('Calculation expression fails the independent boundary specification')
            if any(token in test for token in ('OrderSend','CTrade','trade.Buy','trade.Sell')):failures.append('Trading call in isolated test')
            if not all(re.search(r'ClampCount\s*\(\s*'+str(c['n'])+r'\s*,\s*'+str(c['maximum'])+r'\s*\)',test) for c in cases) or not final['limitations']:failures.append('Missing specified test case or native execution limitation')
    except (OSError,ValueError,KeyError,TypeError,AttributeError):failures.append('Required evidence artifact missing or invalid')
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
    result['evaluator_sha256']={p.name:sha(p) for p in (Path(__file__),Path(__file__).with_name('workflow_process.py'),REPO/'tests/evaluation-cases.json')}
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
    for case in args.case or CASES:
        for arm,source in (('baseline',args.baseline_skill_root),('candidate',args.skill_root)):
            for repetition in range(1,args.repetitions+1):
                runroot=args.output/(case+'-'+arm+'-'+str(repetition));runroot.mkdir();work=runroot/'workspace';work.mkdir();skill=work/'.agents/skills/mql5-coding';shutil.copytree(source,skill)
                context=prepare(case,work,skill,args.powershell,args.python,binaries)
                prompt='Use the MQL5 coding skill at '+str(skill/'SKILL.md')+'. Work only in this disposable workspace. '+context['task']+' Do not use real MetaEditor/MT5, trade, change installed packages, publish, or ask for permission. Treat synthetic executables only as workflow test doubles. Write the required artifacts, then return the structured conclusion with case_id '+case+'. Absolute Python: '+str(args.python)+'. PowerShell: '+str(args.powershell)+'.'
                (runroot/'prompt.txt').write_text(prompt,encoding='utf-8');save(runroot/'input-hashes.json',context['input_hashes'])
                settings=disabled+[{'path':str(skill),'enabled':True}]
                settings_toml='['+','.join('{path='+json.dumps(s['path'])+',enabled='+str(s['enabled']).lower()+'}' for s in settings)+']'
                command=[str(args.codex_path),'-a','never','-c','skills.config='+settings_toml,'-c','model_reasoning_effort='+json.dumps(effort),'-c','web_search="disabled"','-c','windows.sandbox="unelevated"','-c','shell_environment_policy.ignore_default_excludes=false','-c','mcp_servers.mql5-chm.command='+json.dumps(str(args.mcp_package_root/'runtime/node.exe')),'-c','mcp_servers.mql5-chm.args='+json.dumps([str(args.mcp_package_root/'app/server.mjs')]),'exec','--ignore-user-config','--ignore-rules','--ephemeral','--sandbox','workspace-write','--skip-git-repo-check','--json','--model',model,'-C',str(work),'--output-schema',str(args.output/'response.schema.json'),'-o',str(runroot/'final.json'),prompt]
                temporary=work/'.temp';temporary.mkdir()
                run_env={**execution_env,'TEMP':str(temporary),'TMP':str(temporary)}
                started=time.time();measurement=run_owned(command,work,runroot/'trace.jsonl',runroot/'stderr.txt',env=run_env,seconds=args.timeout_seconds)
                try:events,errors=read_trace(runroot/'trace.jsonl')
                except (OSError,UnicodeError):events,errors=[],['Trace unavailable or invalid encoding']
                try:final=load(runroot/'final.json')
                except (OSError,ValueError):final=None;errors.append('Final output unavailable or malformed')
                errors+=grade(case,work,final,events,context['input_hashes'])
                if any(e.get('type') in ('turn.failed','error') or (e.get('item') or {}).get('type')=='error' for e in events):errors.append('CLI trace contains an execution/model error; no fallback or silent retry is accepted')
                if measurement['status']!='completed' or measurement['exit_code']!=0 or not measurement['cleanup_verified']:errors.append('CLI execution incomplete, failed, or cleanup unverified')
                usage=next((e.get('usage') for e in reversed(events) if e.get('type')=='turn.completed'),None)
                commands=[e['item'] for e in events if e.get('type')=='item.completed' and (e.get('item') or {}).get('type')=='command_execution']
                command_text=[c.get('command','') for c in commands]
                item={'case':case,'arm':arm,'repetition':repetition,'status':'passed' if not errors else 'failed','issues':errors,'measurement':{**measurement,'commands':len(commands),'repeated_identical_commands':len(command_text)-len(set(command_text)),'runner_retries':0,'agent_retries':None,'retry_count_reason':'Semantic agent retries are not a stable trace metric; repeated identical completed commands are recorded separately','token_usage':usage,'token_usage_reason':None if usage else 'Usage unavailable in the emitted CLI trace','artifact_bytes':sum(p.stat().st_size for p in work.rglob('*') if p.is_file())},'trace':str(runroot/'trace.jsonl'),'trace_sha256':sha(runroot/'trace.jsonl'),'started_unix_seconds':started}
                result['runs'].append(item);save(runroot/'score.json',item);save(args.output/'progress.json',result);print(case+' '+arm+' '+str(repetition)+': '+item['status'],flush=True)
                if not measurement['cleanup_verified']:result['status']='aborted';save(args.output/'evaluation.json',result);return 2
    for source,previous in originals.items():
        if inventory(Path(source))!=previous:raise RuntimeError('Evaluation changed an original skill tree')
    candidates=[r for r in result['runs'] if r['arm']=='candidate'];result['candidate_passed']=bool(candidates) and all(r['status']=='passed' for r in candidates);result['status']='passed' if result['candidate_passed'] else 'failed';save(args.output/'evaluation.json',result)
    credentials.cleanup()
    return 0 if result['candidate_passed'] else 1

if __name__=='__main__':sys.exit(main())
