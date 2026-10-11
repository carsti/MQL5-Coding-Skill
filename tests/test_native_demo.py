"""Dedicated-demo validation and redaction; synthetic execution is not native proof."""
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import json, os, shutil, subprocess, sys, tempfile, unittest
import native_integration as native
REPO=Path(__file__).resolve().parents[1];SKILL=REPO/'skills/mql5-coding'
AUTH={'login':'123456789','server':'MetaQuotes-Demo','password':'Dedicated-Secret-Only'}
HOSTS=[p for p in (Path(os.environ['ProgramFiles'])/'PowerShell/7/pwsh.exe',Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/powershell.exe') if p.is_file()]

class PrivateAuthentication(unittest.TestCase):
 def test_valid_and_rejected_roots_and_values(self):
  with tempfile.TemporaryDirectory() as temporary:
   path=Path(temporary)/'auth.json';native.save(path,AUTH);self.assertEqual(native.demo_auth(path),AUTH)
   invalid=[None,[],[AUTH],[AUTH,AUTH],1,'secret',{},dict(AUTH,extra=True)]
   for key,value in [('login',123456789),('login','0'),('login','9223372036854775808'),('login','１２３'),('server','other'),('password',''),('password','x\ny'),('password','x\x00y'),('password','\ud800')]:invalid.append(dict(AUTH,**{key:value}))
   for value in invalid:
    with self.subTest(value=repr(value)):
     native.save(path,value)
     with self.assertRaises(native.GateFailure) as failure:native.demo_auth(path)
     self.assertEqual(str(failure.exception),'Private dedicated-demo authentication input is invalid')
   path.write_text('not-json '+AUTH['password'])
   with self.assertRaises(native.GateFailure) as failure:native.demo_auth(path)
   self.assertNotIn(AUTH['password'],str(failure.exception))
 def test_probe_has_no_trading_and_rejects_tester_identity(self):
  source=native.active_mql5((REPO/'tests/NativeDemoProbe.mq5').read_text())
  self.assertNotRegex(source,r'\b(?:OrderSend|OrderSendAsync|CTrade|MqlTradeRequest)\b')
  for identity in ('MQL_TESTER','TERMINAL_CONNECTED','ACCOUNT_LOGIN','ACCOUNT_SERVER','ACCOUNT_TRADE_MODE','ACCOUNT_TRADE_MODE_DEMO'):self.assertIn(identity,source)
  self.assertIn('attempt<360',source)
 @unittest.skipUnless(os.name=='nt','Private Windows terminal configuration')
 def test_verified_default_selection_without_plaintext_password(self):
  with tempfile.TemporaryDirectory() as temporary:
   data=Path(temporary);config=data/'config';config.mkdir();common=config/'common.ini';accounts=config/'accounts.dat'
   common.write_text('[Common]\nEnableNews=0\n',encoding='utf-16')
   with self.assertRaises(native.GateFailure):native.persist_demo_selection(data,AUTH)
   accounts.write_bytes(b'encrypted-fixture')
   for text in ('[Common]\n[Other]\n','[Common]\n[Common]\n'):
    common.write_text(text,encoding='utf-16')
    with self.assertRaises(native.GateFailure):native.persist_demo_selection(data,AUTH)
   common.write_text('[Common]\nEnableNews=0\nLogin=999\nServer=old\nPassword=old-secret\n',encoding='utf-16')
   result=native.persist_demo_selection(data,AUTH);text=common.read_text(encoding='utf-16')
   self.assertEqual(result['status'],'verified_demo_selected');self.assertFalse(result['password_written'])
   self.assertIn('EnableNews=0',text);self.assertIn('Login='+AUTH['login'],text);self.assertIn('Server=MetaQuotes-Demo',text)
   self.assertNotIn('Password=',text);self.assertNotIn(AUTH['password'],text);self.assertNotIn('old-secret',text)
   self.assertNotIn(AUTH['login'],json.dumps(result));self.assertEqual(accounts.read_bytes(),b'encrypted-fixture')

@unittest.skipUnless(os.name=='nt','Windows security and PowerShell evidence')
class BootstrapEvidence(unittest.TestCase):
 def test_native_journals_and_private_console_redaction_both_hosts(self):
  for host in HOSTS:
   with self.subTest(host=host),tempfile.TemporaryDirectory(prefix='m5-demo-test-',dir='C:/') as temporary:
    root=Path(temporary);data=root/'data';(data/'MQL5/Logs').mkdir(parents=True);private=root/'private';private.mkdir();native.protect_private(private)
    auth=private/'auth.json';native.save(auth,AUTH);marker=private/'marker.txt';expected='MQL5_CODING_PASS:'+'b'*32+':dedicated-demo-account';marker.write_text(expected)
    (private/'bootstrap.stdout.txt').write_text('password='+AUTH['password']+' login='+AUTH['login']+' '+expected)
    journal=data/'MQL5/Logs/20250112.log';journal.write_text('0\t12:00:00\tNativeDemoProbe\t'+expected+'\n',encoding='utf-16')
    evidence=root/'evidence.json'
    args={'SkillRoot':SKILL,'TerminalDataRoot':data,'DemoAuthFile':auth,'ExpectedMarkerFile':marker,'PrivateOutputRoot':private,'OutputFile':evidence}
    result,_=native.delegate(host,REPO/'tests/Read-NativeBootstrapEvidence.ps1',args,root,'valid',seconds=30)
    self.assertEqual(result['exit_code'],0);proof=native.load(evidence);self.assertEqual(proof['matching_markers'],1)
    self.assertEqual(proof['sources'][0]['sha256'],native.sha(journal))
    for secret in (AUTH['password'],AUTH['login'],expected):self.assertNotIn(secret,evidence.read_text())
    invalid=[('', 'missing'),('0\t12:00\tprobe\tMQL5_DEMO_PROBE:account-rejected\n','rejected'),('0\t12:00\tprobe\t'+expected+'\n'+'0\t12:01\tprobe\t'+expected+'\n','duplicate'),('printed '+expected+'\n','incomplete')]
    for text,label in invalid:
     journal.write_text(text,encoding='utf-16')
     result,_=native.delegate(host,REPO/'tests/Read-NativeBootstrapEvidence.ps1',args,root,label,seconds=30)
     self.assertEqual(result['exit_code'],2);self.assertEqual(native.load(evidence)['status'],'failed')
    journal.write_text('0\t12:00\tprobe\t'+expected+'\n',encoding='utf-16')
    for number,value in enumerate(([AUTH],[],None,'private-secret',dict(AUTH,extra=1),dict(AUTH,server=['MetaQuotes-Demo']))):
     native.save(auth,value)
     result,_=native.delegate(host,REPO/'tests/Read-NativeBootstrapEvidence.ps1',args,root,'auth-'+str(number),seconds=30)
     self.assertEqual(result['exit_code'],2);self.assertNotIn('private-secret',evidence.read_text())

@unittest.skipUnless(os.name=='nt','Windows synthetic bootstrap')
class BootstrapExecution(unittest.TestCase):
 def test_bootstrap_completion_and_account_rejection_both_hosts(self):
  with tempfile.TemporaryDirectory(prefix='m5-demo-chain-',dir='C:/') as temporary:
   base=Path(temporary);binaries=base/'bin';binaries.mkdir();compiler=Path(os.environ['WINDIR'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
   subprocess.run([str(compiler),'/nologo','/out:'+str(binaries/'MetaEditor64.exe'),str(REPO/'tests/FakeMetaEditor.cs')],capture_output=True,check=True)
   code=base/'terminal.cs';code.write_text('''using System;using System.IO;using System.Text;using System.Reflection;
[assembly:AssemblyFileVersion("5.0.0.1234")]
class Fixture {static void Main(string[] args) {
 string data=Environment.GetEnvironmentVariable("DEMO_TEST_DATA");
 string preset=File.ReadAllText(Path.Combine(data,"MQL5","presets","demo-probe.set"),Encoding.Unicode);
 string nonce=System.Text.RegularExpressions.Regex.Match(preset,@"ProbeNonce=([0-9a-f]{32})").Groups[1].Value;
 string mode=Environment.GetEnvironmentVariable("DEMO_TEST_MODE");
 string message=mode.StartsWith("valid") ? "MQL5_CODING_PASS:"+nonce+":dedicated-demo-account" : "MQL5_DEMO_PROBE:account-rejected";
 Directory.CreateDirectory(Path.Combine(data,"MQL5","Logs"));
 Directory.CreateDirectory(Path.Combine(data,"config"));
 File.WriteAllBytes(Path.Combine(data,"config","accounts.dat"),new byte[]{1,2,3});
 File.WriteAllText(Path.Combine(data,"config","common.ini"),"[Common]\\r\\n",Encoding.Unicode);
 File.WriteAllText(Path.Combine(data,"MQL5","Logs","20250112.log"),"0\\t12:00:00\\tNativeDemoProbe\\t"+message+"\\r\\n",Encoding.Unicode);
 Console.WriteLine("password=Dedicated-Secret-Only login=123456789");
 if(mode=="valid-shutdown") Environment.Exit(3);
 }}''')
   subprocess.run([str(compiler),'/nologo','/out:'+str(binaries/'terminal64.exe'),str(code)],capture_output=True,check=True)
   for host in HOSTS:
    for mode in ('valid','valid-shutdown','real','contest','unknown','mismatched','disconnected'):
     with self.subTest(host=host,mode=mode):
      root=base/(host.stem+'-'+mode);root.mkdir();data=root/'data';data.mkdir();project=root/'project';project.mkdir();install=root/'install';shutil.copytree(binaries,install)
      auth=base/'auth.json';native.save(auth,AUTH);record={}
      args=SimpleNamespace(demo_auth_file=auth,skill_root=SKILL,powershell=host,timeout_seconds=30)
      with patch.dict(os.environ,{'DEMO_TEST_DATA':str(data),'DEMO_TEST_MODE':mode}):
       if mode.startswith('valid'):native.bootstrap_demo(args,root,install,data,project,record)
       else:self.assertRaises(native.GateFailure,native.bootstrap_demo,args,root,install,data,project,record)
      self.assertEqual(record['demo_bootstrap']['status'],'verified' if mode.startswith('valid') else 'failed')
      self.assertTrue(record['demo_bootstrap']['temporary_plaintext_removed']);self.assertFalse((data/'MQL5/presets/demo-probe.set').exists())
      for path in root.glob('*.json'):
       for secret in (AUTH['login'],AUTH['password']):self.assertNotIn(secret,path.read_text())
 def test_uncertain_cleanup_blocks_and_retains_restricted_plaintext(self):
  with tempfile.TemporaryDirectory(prefix='m5-demo-cleanup-',dir='C:/') as temporary:
   root=Path(temporary);data=root/'data';data.mkdir();project=root/'project';project.mkdir();install=root/'install';install.mkdir();(install/'terminal64.exe').write_bytes(b'fake');auth=root/'auth.json';native.save(auth,AUTH)
   artifact=project/'probe.ex5';artifact.write_bytes(b'probe');receipt=project/'receipt.json';native.save(receipt,{'expert':{'path':str(artifact),'sha256':native.sha(artifact)}})
   def runner(command,work,out,err,**kwargs):out.write_text('private');err.write_text('');return {'status':'timed_out','exit_code':None,'cleanup_verified':False,'console_bytes':7}
   args=SimpleNamespace(demo_auth_file=auth,skill_root=SKILL,powershell=HOSTS[0],timeout_seconds=30);record={}
   before=set((Path.home()/'.codex-native-auth').glob('bootstrap-*'))
   with patch.object(native,'delegate',return_value=({'exit_code':0},'MQL5_COMPILE_RECEIPT='+str(receipt))),patch.object(native,'successful_receipt',return_value=native.load(receipt)),patch.object(native,'run_owned',side_effect=runner):
    self.assertRaisesRegex(native.GateFailure,'cleanup is uncertain',native.bootstrap_demo,args,root,install,data,project,record)
   private=list(set((Path.home()/'.codex-native-auth').glob('bootstrap-*'))-before)
   self.assertEqual(len(private),1);self.assertTrue((private[0]/'bootstrap.ini').is_file());self.assertFalse(record['demo_bootstrap']['temporary_plaintext_removed'])
   # The synthetic runner launched no process; remove this test's known files.
   for path in private[0].iterdir():self.assertEqual(native.ordinary(path).parent,private[0]);path.unlink()
   private[0].rmdir()

 def test_evidence_reader_cleanup_uncertainty_retains_private_inputs(self):
  with tempfile.TemporaryDirectory(prefix='m5-demo-reader-',dir='C:/') as temporary:
   root=Path(temporary);data=root/'data';data.mkdir();project=root/'project';project.mkdir();install=root/'install';install.mkdir();(install/'terminal64.exe').write_bytes(b'fake');auth=root/'auth.json';native.save(auth,AUTH)
   artifact=project/'probe.ex5';artifact.write_bytes(b'probe');receipt=project/'receipt.json';native.save(receipt,{'expert':{'path':str(artifact),'sha256':native.sha(artifact)}})
   def reader(host,script,parameters,work,label,**kwargs):
    if label=='demo-probe-compile':return {'exit_code':0},'MQL5_COMPILE_RECEIPT='+str(receipt)
    native.save(root/'demo-bootstrap-evidence-process.json',{'cleanup_verified':False})
    raise native.GateFailure('Delegated process cleanup is uncertain')
   def runner(command,work,out,err,**kwargs):out.write_text('');err.write_text('');return {'status':'completed','exit_code':0,'cleanup_verified':True,'console_bytes':0}
   args=SimpleNamespace(demo_auth_file=auth,skill_root=SKILL,powershell=HOSTS[0],timeout_seconds=30);record={};before=set((Path.home()/'.codex-native-auth').glob('bootstrap-*'))
   with patch.object(native,'delegate',side_effect=reader),patch.object(native,'successful_receipt',return_value=native.load(receipt)),patch.object(native,'run_owned',side_effect=runner):
    self.assertRaisesRegex(native.GateFailure,'cleanup is uncertain',native.bootstrap_demo,args,root,install,data,project,record)
   private=list(set((Path.home()/'.codex-native-auth').glob('bootstrap-*'))-before)
   self.assertEqual(len(private),1);self.assertTrue((private[0]/'demo-auth.json').is_file());self.assertFalse(record['demo_bootstrap']['temporary_plaintext_removed'])
   # Synthetic processes did not launch: clean only the known owned files.
   for path in private[0].iterdir():self.assertEqual(native.ordinary(path).parent,private[0]);path.unlink()
   private[0].rmdir()

if __name__=='__main__':unittest.main()
