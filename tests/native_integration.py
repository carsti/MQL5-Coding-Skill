"""Development-only nontrading integration gate with optional dedicated demo.

Default preflight inspects metadata and cache/fixture inputs without launching
MetaEditor or MT5. Execute delegates to reviewed production helpers. It never
copies existing accounts, configuration, profiles, credentials, or EAs.
"""
from __future__ import annotations
import argparse, ast, base64, hashlib, json, os, re, shutil, sys, tempfile, uuid
from pathlib import Path
from workflow_process import run_owned
from evaluate_workflows import active_mql5

SETTINGS={'Symbol':'EURUSD','Period':'M1','FromDate':'2025.01.12','ToDate':'2025.02.28','Model':0,'Deposit':'100000','Currency':'USD','Leverage':100,'ExecutionMode':0}
CASES=[('ClampExample',(-9,),-2),('ClampExample',(-2,),-2),('ClampExample',(0,),0),('ClampExample',(3,),3),('ClampExample',(9,),3),('StepExample',(0,False),1),('StepExample',(1,False),2),('StepExample',(2,False),2),('StepExample',(0,True),3),('StepExample',(1,True),3),('StepExample',(3,False),3)]

class GateFailure(ValueError):pass

def demo_auth(path):
 """Private selectors are never included in returned evidence or errors."""
 try:
  path=ordinary(path)
  if path.stat().st_size>16384:raise ValueError()
  value=load(path)
  if set(value)!={'login','server','password'}:raise ValueError()
  login,password=value['login'],value['password']
  if not isinstance(login,str) or not re.fullmatch('[1-9][0-9]{0,18}',login) or int(login)>9223372036854775807:raise ValueError()
  if value['server']!='MetaQuotes-Demo' or not isinstance(password,str) or not password or re.search('[\r\n\x00]',password):raise ValueError()
  password.encode('utf-16')
  return value
 except (OSError,ValueError,TypeError,KeyError,RecursionError):raise GateFailure('Private dedicated-demo authentication input is invalid') from None

def protect_private(path):
 """Current owner and SYSTEM only; no inherited credential access."""
 import ctypes
 from ctypes import wintypes as W
 path=ordinary(path)
 advapi=ctypes.WinDLL('advapi32',use_last_error=True);kernel=ctypes.WinDLL('kernel32',use_last_error=True)
 advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes=[W.LPCWSTR,W.DWORD,ctypes.POINTER(ctypes.c_void_p),ctypes.POINTER(W.DWORD)]
 advapi.SetFileSecurityW.argtypes=[W.LPCWSTR,W.DWORD,ctypes.c_void_p]
 kernel.LocalFree.argtypes=[ctypes.c_void_p];kernel.LocalFree.restype=ctypes.c_void_p
 descriptor=ctypes.c_void_p()
 acl='D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;SY)' if path.is_dir() else 'D:P(A;;FA;;;OW)(A;;FA;;;SY)'
 if not advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW(acl,1,ctypes.byref(descriptor),None):raise GateFailure('Private authentication ACL initialization failed')
 try:
  if not advapi.SetFileSecurityW(str(path),0x80000004,descriptor):raise GateFailure('Private authentication ACL protection failed')
 finally:kernel.LocalFree(descriptor)

def sha(path):
 with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def load(path):
 value=json.loads(Path(path).read_text(encoding='utf-8-sig'))
 if not isinstance(value,dict):raise GateFailure('Evidence root must be an object')
 return value
def save(path,value):Path(path).write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
def ordinary(path):
 path=Path(path).absolute()
 # Inspect the original ancestry before normalization can hide a component
 # behind "..". Derive later installation identities from the normalized path.
 for entry in (path,*path.parents):
  try:metadata=entry.lstat()
  except FileNotFoundError:continue
  if metadata.st_file_attributes & 0x400:raise GateFailure('Reparse inputs are unsupported')
 return Path(os.path.abspath(path))

def verify_fixture(skill):
 source=Path(skill)/'assets/Mql5ToolkitSelfTest.mq5';header=Path(skill)/'assets/Mql5Assertions.mqh'
 code=active_mql5(source.read_text(encoding='utf-8-sig'));include=active_mql5(header.read_text(encoding='utf-8-sig'))
 if code is None or include is None:raise GateFailure('Fixture lexer failed')
 if re.search(r'\b(?:OrderSend|OrderSendAsync|CTrade|MqlTradeRequest|trade\.\w+)\b',code+'\n'+include):raise GateFailure('Unexpected trading call or trading structure')
 matches=re.findall(r'test\.Check\(\s*(ClampExample|StepExample)\(([^)]*)\)\s*==\s*(-?[0-9]+)\s*,\s*"[^"\r\n]+"\s*\);',code)
 actual=[]
 for function,args,expected in matches:
  values=tuple(False if s.strip()=='false' else True if s.strip()=='true' else int(s) for s in args.split(','))
  actual.append((function,values,int(expected)))
 if actual!=CASES or len(re.findall(r'\btest\.Check\s*\(',code))!=11:raise GateFailure('Eleven independently specified assertions changed')
 # Bounded statement interpreter for these two fixtures; no input code executes.
 def expression(text,variables):
  node=ast.parse(text.replace('||',' or ').replace('&&',' and '),mode='eval').body
  def value(n):
   if isinstance(n,ast.Constant) and type(n.value) in (int,bool):return n.value
   if isinstance(n,ast.Name) and n.id in variables:return variables[n.id]
   if isinstance(n,ast.UnaryOp) and isinstance(n.op,ast.USub):return -value(n.operand)
   if isinstance(n,ast.BoolOp) and isinstance(n.op,(ast.Or,ast.And)):return (any if isinstance(n.op,ast.Or) else all)(value(x) for x in n.values)
   if isinstance(n,ast.Compare) and len(n.ops)==1 and isinstance(n.ops[0],(ast.Lt,ast.Gt,ast.Eq)):
    left,right=value(n.left),value(n.comparators[0]);return left<right if isinstance(n.ops[0],ast.Lt) else left>right if isinstance(n.ops[0],ast.Gt) else left==right
   raise GateFailure('Unsupported fixture expression')
  return value(node)
 for name,arguments,expected in CASES:
  match=re.search(r'int\s+'+name+r'\([^)]*\)\s*\{([^{}]*)\}',code)
  if not match:raise GateFailure('Unsupported fixture function')
  variables=dict(zip(('x',) if name=='ClampExample' else ('state','fault'),arguments))
  body=match[1];position=0;answer=None
  pattern=re.compile(r'\s*(?:if\(([^)]*)\)\s*)?return\(([^)]*)\);')
  while position<len(body) and body[position:].strip():
   statement=pattern.match(body,position)
   if not statement:raise GateFailure('Unsupported fixture statement')
   position=statement.end()
   if statement[1] is None or expression(statement[1],variables):answer=expression(statement[2],variables);break
  if answer!=expected:raise GateFailure('Fixture calculation differs from independent expected value')
 return {'assertions':11,'cases':[{'function':f,'arguments':list(a),'expected':e} for f,a,e in CASES],'source_sha256':sha(source),'include_sha256':sha(header),'scope':'Bounded static specification check; native compiler and tester evidence remains separately required.'}

def host_env(host):
 env=dict(os.environ);env['PYTHONDONTWRITEBYTECODE']='1'
 if Path(host).name.lower()=='powershell.exe':
  env['PSModulePath']=os.pathsep.join([str(Path(os.environ['USERPROFILE'])/'Documents/WindowsPowerShell/Modules'),str(Path(os.environ['ProgramFiles'])/'WindowsPowerShell/Modules'),str(Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/Modules')])
 return env

def delegate(host,script,parameters,work,label,*,seconds=660):
 quote=lambda x:"'"+str(x).replace("'","''")+"'"
 command='& '+quote(script)
 for name,value in parameters.items():
  if not re.fullmatch('[A-Za-z][A-Za-z0-9]*',name):raise GateFailure('Invalid delegated parameter')
  if isinstance(value,bool):
   if value:command+=' -'+name
  else:command+=' -'+name+' '+quote(value)
 command+='; exit $LASTEXITCODE'
 args=[str(host),'-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',base64.b64encode(command.encode('utf-16le')).decode()]
 result=run_owned(args,work,work/(label+'.stdout.txt'),work/(label+'.stderr.txt'),env=host_env(host),seconds=seconds)
 save(work/(label+'-process.json'),result)
 if not result['cleanup_verified']:raise GateFailure('Delegated process cleanup is uncertain')
 if result['console_bytes']>16777216:raise GateFailure('Delegated output exceeds supported bound')
 if result['status']!='completed':raise GateFailure('Delegated execution is incomplete: '+result['status'])
 return result, (work/(label+'.stdout.txt')).read_text(encoding='utf-8-sig')

def selected_output(text,key):
 values=[line[len(key)+1:] for line in text.splitlines() if line.startswith(key+'=')]
 if len(values)!=1 or not Path(values[0]).is_absolute():raise GateFailure('Missing or ambiguous '+key)
 return Path(values[0])

def successful_receipt(path):
 receipt=load(path)
 if receipt.get('status')!='success' or receipt.get('errors')!=0 or receipt.get('warnings')!=0 or receipt.get('exit_code')!=0:raise GateFailure('Compilation did not have zero errors/warnings')
 for field in ('source','expert','log','compiler'):
  record=receipt[field];p=ordinary(record['path'])
  if p.stat().st_size!=record['byte_length'] or sha(p)!=record['sha256']:raise GateFailure('Compilation commitment mismatch: '+field)
 return receipt

def redact_fixture_nonce(journal,nonce):
 # The production helper masks complete application markers. MT5 separately
 # echoes TestNonce as an input; sanitize only observation strings in this
 # development-specific copy, preserving source/segment hashes and counts.
 result=json.loads(json.dumps(journal));changed=0
 for group in result.get('groups',[]):
  for field in ('component','message','representative_excerpt'):
   value=group.get(field)
   if isinstance(value,str) and nonce in value:
    changed+=value.count(nonce);group[field]=value.replace(nonce,'<TEST_NONCE>')
 return result,changed

def verify_native_evidence(run,journal,report,nonce):
 if run.get('status')!='application_marker_passed' or run.get('process',{}).get('exit_code')!=0:raise GateFailure('Native tester did not complete with the selected application marker')
 expected_marker=hashlib.sha256(('MQL5_CODING_PASS:'+nonce+':toolkit-selftest').encode()).hexdigest()
 if run.get('inputs',{}).get('expected_log_marker_sha256')!=[expected_marker] or run.get('evidence',{}).get('checks',{}).get('expected_markers_matched') is not True:raise GateFailure('Unique marker commitment was not verified')
 process=run.get('process',{});cleanup=run.get('cleanup',{})
 if not all(process.get(k) is True for k in ('execution_attempted','process_created','resumed','job_empty_verified','post_exit_no_matching_terminal','post_exit_no_potential_descendants')) or cleanup.get('errors'):raise GateFailure('Native process completion/cleanup is unverified')
 if journal.get('status')!='completed' or journal.get('truncated') or journal.get('evidence_status')!='complete_segments':raise GateFailure('Journal processing has incomplete evidence')
 groups=journal.get('groups',[])
 if not any('MQL5_TEST_COUNTS:checked=11,failed=0' in g.get('message','') and g.get('count')==1 for g in groups) or any('MQL5_TEST_FAIL:' in g.get('message','') for g in groups):raise GateFailure('Native eleven-assertion count missing or failed')
 if nonce in json.dumps(journal) or 'MQL5_CODING_PASS:' in json.dumps(journal):raise GateFailure('Journal exposed marker plaintext')
 if report.get('parsing',{}).get('status')!='success' or report.get('evidence_linkage',{}).get('status')!='hash_verified' or report.get('recorded_run',{}).get('status')!='application_marker_passed':raise GateFailure('Report is unlinked, stale or unsuccessfully parsed')
 for name in ('trades','deals'):
  metric=report.get('metrics',{}).get(name,{})
  if metric.get('state')!='finite' or metric.get('value')!='0':raise GateFailure('Native report does not establish zero '+name)

def prepare_terminal(platform,cache,runroot,skill):
 root=ordinary(runroot)
 if root.exists() or len(str(root))>100:raise GateFailure('Select a fresh short run root (at most 100 characters)')
 root.mkdir(parents=True);install=root/'terminal';install.mkdir()
 # Actual MT5 data identity: MD5 of uppercase canonical installation path in
 # UTF-16LE; checked against the donor origin mapping in the recorded preflight.
 identity=hashlib.md5(str(install).upper().encode('utf-16le')).hexdigest().upper()
 data=ordinary(Path(os.environ['APPDATA'])/'MetaQuotes/Terminal'/identity)
 if data.exists():raise GateFailure('Refusing an existing terminal data identity')
 data.mkdir(parents=True)
 copied=[]
 def copy(source,destination):
  source=ordinary(source);destination.parent.mkdir(parents=True,exist_ok=True)
  shutil.copy2(source,destination)
  if sha(source)!=sha(destination):raise GateFailure('Copied input changed')
  copied.append({'source':str(source),'destination':str(destination),'sha256':sha(destination),'bytes':destination.stat().st_size})
 for name in ('MetaEditor64.exe','terminal64.exe','metatester64.exe'):copy(Path(platform)/name,install/name)
 for directory in ('MQL5/Experts','MQL5/Profiles/Tester','Tester/logs','logs'):(data/directory).mkdir(parents=True,exist_ok=True)
 (data/'origin.txt').write_text(str(install),encoding='utf-16')
 project=root/'project';project.mkdir()
 for name in ('Mql5ToolkitSelfTest.mq5','Mql5Assertions.mqh'):copy(Path(skill)/'assets'/name,project/name)
 base=Path(cache)/'bases/MetaQuotes-Demo';destination=data/'bases/MetaQuotes-Demo'
 copy(base/'history/EURUSD/2025.hcc',destination/'history/EURUSD/2025.hcc')
 # Only symbol definitions/selection and the selected symbol's cached ticks.
 for source in sorted((base/'symbols').glob('*.dat')):copy(source,destination/'symbols'/source.name)
 ticks=base/'ticks/EURUSD'
 if ticks.is_dir():
  for source in sorted(ticks.glob('*.dat')):copy(source,destination/'ticks/EURUSD'/source.name)
 for forbidden in ('accounts.dat','accounts.ini','config','Config','Profiles','profiles'):
  if (install/forbidden).exists() or (data/forbidden).exists():raise GateFailure('Credential/configuration material was copied')
 return root,install,data,project,copied

def persist_demo_selection(data,auth):
 # /config inputs are read-only and do not persist the selected login. The
 # tester's separate configuration therefore needs the verified demo selected
 # in this fresh terminal's default Common settings. Passwords stay only in the
 # terminal-created encrypted account database, never in this configuration.
 directory=ordinary(data/'config');accounts=ordinary(directory/'accounts.dat')
 if not accounts.is_file() or accounts.stat().st_size==0:raise GateFailure('Verified demo account database was not retained')
 path=ordinary(directory/'common.ini')
 if not path.is_file() or path.stat().st_size>65536:raise GateFailure('Private default terminal configuration is unavailable')
 try:
  raw=path.read_bytes();text=raw.decode('utf-16') if raw[:2] in (b'\xff\xfe',b'\xfe\xff') else raw.decode('utf-8-sig')
 except (UnicodeError,OSError):raise GateFailure('Private default terminal configuration is unreadable') from None
 lines=text.splitlines();sections=[line.strip() for line in lines if line.strip().startswith('[')]
 if sections!=['[Common]']:raise GateFailure('Private default terminal configuration has unsupported sections')
 owned={'login','server','keepprivate','password'}
 kept=[line for line in lines if line.partition('=')[0].strip().lower() not in owned]
 protect_private(path)
 path.write_text('\n'.join(kept+['Login='+auth['login'],'Server='+auth['server'],'KeepPrivate=1'])+'\n',encoding='utf-16')
 return {'status':'verified_demo_selected','configuration_sha256':sha(path),'account_database_sha256':sha(accounts),'password_written':False}

def bootstrap_demo(args,root,install,data,project,record):
 auth=demo_auth(args.demo_auth_file);nonce=uuid.uuid4().hex
 # Preserve the inspected account mode separately from tester simulation.
 record['demo_bootstrap']={'status':'failed','scope':'Native script outside Strategy Tester; exact connected dedicated-demo identity required.'}
 source=project/'NativeDemoProbe.mq5';shutil.copy2(Path(__file__).with_name('NativeDemoProbe.mq5'),source)
 probe=active_mql5(source.read_text(encoding='utf-8'))
 if probe is None or re.search(r'\b(?:OrderSend|OrderSendAsync|CTrade|MqlTradeRequest)\b',probe):raise GateFailure('Unexpected probe trading call')
 response,text=delegate(args.powershell,args.skill_root/'scripts/Compile-Mql5.ps1',{'SourcePath':source,'MetaEditorPath':install/'MetaEditor64.exe','WarningsAsErrors':True,'SuppressLogOutput':True},root,'demo-probe-compile')
 if response['exit_code']!=0:raise GateFailure('Native account probe compilation failed')
 receipt_path=selected_output(text,'MQL5_COMPILE_RECEIPT');receipt=successful_receipt(receipt_path)
 scripts=data/'MQL5/Scripts';scripts.mkdir(parents=True,exist_ok=True)
 artifact=scripts/'NativeDemoProbe.ex5';shutil.copy2(Path(receipt['expert']['path']),artifact)
 if sha(artifact)!=receipt['expert']['sha256']:raise GateFailure('Native account probe artifact commitment changed')
 private_parent=ordinary(Path.home()/'.codex-native-auth');private_parent.mkdir(exist_ok=True);protect_private(private_parent)
 private=ordinary(Path(tempfile.mkdtemp(prefix='bootstrap-',dir=private_parent)));protect_private(private)
 preset=data/'MQL5/presets/demo-probe.set';preset.parent.mkdir(parents=True,exist_ok=True)
 # Terminal account databases/configuration remain local private state outside
 # evidence packages. Only sanitized bootstrap observations are retained.
 protect_private(data)
 clean=True
 try:
  auth_copy=private/'demo-auth.json';save(auth_copy,auth)
  marker=private/'expected-marker.txt';expected='MQL5_CODING_PASS:'+nonce+':dedicated-demo-account';marker.write_text(expected+'\n',encoding='utf-8')
  preset.touch(exist_ok=False);protect_private(preset)
  preset.write_text('ExpectedLogin='+auth['login']+'\nExpectedServer='+auth['server']+'\nProbeNonce='+nonce+'\n',encoding='utf-16')
  config=private/'bootstrap.ini'
  config.write_text('[Common]\nLogin='+auth['login']+'\nServer='+auth['server']+'\nPassword='+auth['password']+'\nKeepPrivate=1\nNewsEnable=0\n[Experts]\nEnabled=1\nAllowLiveTrading=0\nAllowDllImport=0\n[StartUp]\nScript=NativeDemoProbe.ex5\nScriptParameters=demo-probe.set\nSymbol=EURUSD\nPeriod=M1\nShutdownTerminal=1\n',encoding='utf-16')
  clean=False
  record['demo_bootstrap']['marker_sha256']=hashlib.sha256(expected.encode()).hexdigest()
  measure=run_owned([str(install/'terminal64.exe'),'/config:'+str(config)],root,private/'bootstrap.stdout.txt',private/'bootstrap.stderr.txt',env=host_env(args.powershell),seconds=args.timeout_seconds)
  clean=measure['cleanup_verified'];save(root/'demo-bootstrap-process.json',measure)
  if not clean:raise GateFailure('Dedicated-demo bootstrap cleanup is uncertain; private plaintext retained with restricted access')
  clean=False
  try:
   response,_=delegate(args.powershell,Path(__file__).with_name('Read-NativeBootstrapEvidence.ps1'),{'SkillRoot':args.skill_root,'TerminalDataRoot':data,'DemoAuthFile':auth_copy,'ExpectedMarkerFile':marker,'PrivateOutputRoot':private,'OutputFile':root/'demo-bootstrap-evidence.json'},root,'demo-bootstrap-evidence',seconds=30)
  finally:
   process_evidence=root/'demo-bootstrap-evidence-process.json'
   if process_evidence.is_file():clean=load(process_evidence).get('cleanup_verified') is True
  if response['exit_code']!=0 or load(root/'demo-bootstrap-evidence.json').get('status')!='verified':raise GateFailure('Native connected account identity, server and demo mode were not verified')
  # Build 6253 returns 3 for the configured StartUp script shutdown. Preserve
  # that native exit and require the exact identity marker before accepting it.
  # The subsequent Strategy Tester still requires its original exit-zero gate.
  if measure['status']!='completed' or measure['exit_code'] not in (0,3) or measure['console_bytes']>16777216:raise GateFailure('Dedicated-demo bootstrap did not complete within supported limits')
  record['demo_bootstrap']['default_selection']=persist_demo_selection(data,auth)
  record['demo_bootstrap'].update({'status':'verified','evidence':str(root/'demo-bootstrap-evidence.json'),'probe_source_sha256':sha(source),'probe_artifact_sha256':sha(artifact),'marker_sha256':hashlib.sha256(expected.encode()).hexdigest()})
 finally:
  if clean:
   # Only delete known files in the task-created, canonical private directory.
   # Uncertain process cleanup retains protected plaintext for manual recovery.
   for name in ('demo-auth.json','expected-marker.txt','bootstrap.ini','bootstrap.stdout.txt','bootstrap.stderr.txt'):
    target=ordinary(private/name)
    if target.parent!=private:raise GateFailure('Private cleanup path escaped its owned root')
    target.unlink(missing_ok=True)
   private.rmdir();ordinary(preset).unlink(missing_ok=True)
  record['demo_bootstrap']['temporary_plaintext_removed']=clean

def execute(args,record):
 root,install,data,project,copied=prepare_terminal(args.platform_root,args.cache_root,args.run_root,args.skill_root)
 record.update({'run_root':str(root),'terminal_data_root':str(data),'copied_inputs':copied,'evidence':'native'})
 if getattr(args,'demo_auth_file',None):bootstrap_demo(args,root,install,data,project,record)
 scripts=args.skill_root/'scripts';nonce=uuid.uuid4().hex;preset=project/'selftest.set';preset.write_text('TestNonce='+nonce+'\n',encoding='utf-16')
 marker=root/'expected-markers.txt';marker.write_text('MQL5_CODING_PASS:'+nonce+':toolkit-selftest\n')
 profile=project/'profile.json'
 def invoke(script,parameters,label):return delegate(args.powershell,scripts/script,parameters,root,label)
 selection={'ProfilePath':profile,'Name':'Credential-free nontrading integration','ProjectRoot':project,'Entrypoints':'Mql5ToolkitSelfTest.mq5','MetaEditorPath':install/'MetaEditor64.exe','IncludePath':project,'WarningsAsErrors':True,'TesterEntrypoint':'Mql5ToolkitSelfTest.mq5','TerminalPath':install/'terminal64.exe','TerminalDataPath':data,'SetPath':preset,'TesterTimeoutSeconds':args.timeout_seconds,**SETTINGS}
 response,_=invoke('New-Mql5ProjectProfile.ps1',selection,'profile')
 if response['exit_code']!=0:raise GateFailure('Native profile creation failed')
 compile_parameters={'ProfilePath':profile,'Action':'Compile','CaptureSourceSnapshot':True,'PythonPath':args.python,'SuppressLogOutput':True}
 response,text=invoke('Invoke-Mql5Project.ps1',compile_parameters,'compile-first')
 if response['exit_code']!=0:raise GateFailure('Native compilation or build verification failed')
 receipt=selected_output(text,'MQL5_COMPILE_RECEIPT');snapshot=selected_output(text,'MQL5_BUILD_SNAPSHOT');successful_receipt(receipt)
 header=project/'Mql5Assertions.mqh';original=header.read_bytes();header.write_bytes(original+b'\r\n// changed native snapshot probe\r\n')
 rejected=root/'changed-header'
 response,rejection_output=invoke('Invoke-Mql5Project.ps1',{'ProfilePath':profile,'Action':'TesterSmoke','CompilationReceiptPath':receipt,'BuildSnapshotPath':snapshot,'ExpectedLogMarkerFile':marker,'OutputDirectory':rejected},'changed-header')
 rejection_path=rejected/'smoke-result.json';rejection=load(rejection_path) if rejection_path.is_file() else None
 rejection_diagnostic=(root/'changed-header.stderr.txt').read_text(encoding='utf-8-sig')
 if response['exit_code']!=2 or 'MQL5_BUILD_SNAPSHOT=' in rejection_output or 'Build snapshot hash, length, or path does not match the selected evidence.' not in rejection_diagnostic or (rejection is not None and (rejection.get('process',{}).get('execution_attempted') is not False or rejection.get('process',{}).get('process_created') is not False)):raise GateFailure('Changed header was not rejected at the snapshot prelaunch gate')
 record['changed_header_rejection']={'exit_code':2,'terminal_started':False,'result':str(rejection_path) if rejection is not None else None,'diagnostic':str(root/'changed-header.stderr.txt'),'scope':'Trusted snapshot verification rejected before its success output and launch branch; result JSON may be absent before output-directory creation.'}
 header.write_bytes(original)
 response,text=invoke('Invoke-Mql5Project.ps1',compile_parameters,'compile-restored')
 if response['exit_code']!=0:raise GateFailure('Restored native fixture did not recompile')
 receipt=selected_output(text,'MQL5_COMPILE_RECEIPT');snapshot=selected_output(text,'MQL5_BUILD_SNAPSHOT');successful_receipt(receipt)
 test=root/'tester';response,_=invoke('Invoke-Mql5Project.ps1',{'ProfilePath':profile,'Action':'TesterSmoke','CompilationReceiptPath':receipt,'BuildSnapshotPath':snapshot,'ExpectedLogMarkerFile':marker,'OutputDirectory':test},'tester')
 run=load(test/'smoke-result.json');record['tester_status']=run.get('status');record['tester_result']=str(test/'smoke-result.json')
 if response['exit_code']!=0:raise GateFailure('Native tester failed; retained evidence, no saved-account fallback')
 response,_=invoke('Read-Mql5Journal.ps1',{'TesterResultPath':test/'smoke-result.json','OutputDirectory':root/'journal'},'journal')
 if response['exit_code']!=0:raise GateFailure('Native journal processing failed')
 journal_source=root/'journal/result.json';journal,redactions=redact_fixture_nonce(load(journal_source),nonce)
 journal_path=root/'native-journal.json';save(journal_path,journal)
 record['journal_redaction']={'source':str(journal_source),'source_sha256':sha(journal_source),'result':str(journal_path),'result_sha256':sha(journal_path),'nonce_occurrences_masked':redactions,'scope':'Only application observation strings; segment/source commitments and counts preserved.'}
 report_path=ordinary(run['artifacts']['report']['path'])
 command=[str(args.python),'-B',str(scripts/'mql5_toolkit.py'),'report','read','--input',str(report_path),'--tester-result',str(test/'smoke-result.json'),'--output',str(root/'report')]
 analysis=run_owned(command,root,root/'report.stdout.txt',root/'report.stderr.txt',env=host_env(args.powershell),seconds=90)
 if analysis['status']!='completed' or analysis['console_bytes']>16777216 or analysis['exit_code']!=0 or not analysis['cleanup_verified']:raise GateFailure('Native linked report analysis failed')
 report=load(root/'report/result.json');verify_native_evidence(run,journal,report,nonce)
 record.update({'status':'passed','compilation_receipt':{'path':str(receipt),'sha256':sha(receipt)},'build_snapshot':{'path':str(snapshot),'sha256':sha(snapshot)},'journal':str(journal_path),'report':str(root/'report/result.json')})

def main(argv=None):
 parser=argparse.ArgumentParser(description=__doc__)
 for name in ('skill-root','platform-root','cache-root','run-root','powershell','output'):parser.add_argument('--'+name,type=Path,required=True)
 parser.add_argument('--python',type=Path,default=Path(sys.executable));parser.add_argument('--action',choices=('preflight','execute'),default='preflight');parser.add_argument('--timeout-seconds',type=int,default=300)
 parser.add_argument('--demo-auth-file',type=Path,help='Private JSON credentials for a newly provisioned dedicated MetaQuotes-Demo account')
 args=parser.parse_args(argv)
 if any(not p.is_absolute() for p in (args.skill_root,args.platform_root,args.cache_root,args.run_root,args.powershell,args.output,args.python)):parser.error('Paths must be absolute')
 if args.demo_auth_file and not args.demo_auth_file.is_absolute():parser.error('Demo authentication path must be absolute')
 if args.output.exists():parser.error('Select a fresh output directory')
 if not 10<=args.timeout_seconds<=600:parser.error('Tester deadline must be 10..600 seconds')
 args.output.mkdir();record={'schema_version':1,'operation':'native_nontrading_integration','action':args.action,'status':'failed','settings':SETTINGS,'issues':[],'powershell':{'path':str(args.powershell),'sha256':sha(args.powershell)},'harness_sha256':sha(__file__)}
 try:
  if args.demo_auth_file:demo_auth(args.demo_auth_file);record['account_selection']='dedicated_demo'
  if args.run_root.exists() or len(str(args.run_root))>100:raise GateFailure('Select a fresh short run root (at most 100 characters)')
  record['fixture_specification']=verify_fixture(args.skill_root)
  inspected,_=delegate(args.powershell,Path(__file__).with_name('Inspect-NativeInputs.ps1'),{'SkillRoot':args.skill_root,'PlatformRoot':args.platform_root,'OutputFile':args.output/'platform-metadata.json'},args.output,'platform-inspection',seconds=30)
  if inspected['exit_code']!=0:raise GateFailure('Native platform metadata validation failed without executable launch')
  record['platform_metadata']=load(args.output/'platform-metadata.json')
  record['platform_inputs']={name:{'path':str(ordinary(args.platform_root/name)),'sha256':sha(args.platform_root/name)} for name in ('MetaEditor64.exe','terminal64.exe','metatester64.exe')}
  history=ordinary(args.cache_root/'bases/MetaQuotes-Demo/history/EURUSD/2025.hcc')
  if history.stat().st_size<=0:raise GateFailure('No usable cached EURUSD 2025 history')
  record['history_input']={'path':str(history),'sha256':sha(history),'bytes':history.stat().st_size}
  if args.action=='preflight':record.update({'status':'preflight_passed','native_execution':False,'limitations':['History availability and metadata hashes do not establish native test completion. Execute is required.']})
  else:execute(args,record)
 except (GateFailure,OSError,ValueError,KeyError,TypeError,RecursionError) as error:record['issues'].append(str(error))
 save(args.output/'result.json',record);print(json.dumps({'status':record['status'],'evidence':str(args.output/'result.json'),'issues':record['issues']}))
 return 0 if record['status'] in ('passed','preflight_passed') else 1
if __name__=='__main__':sys.exit(main())
