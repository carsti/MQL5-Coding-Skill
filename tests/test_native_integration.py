"""Native evidence grading and synthetic helper orchestration, never native proof."""
from pathlib import Path
from types import SimpleNamespace
import hashlib, json, os, shutil, subprocess, sys, tempfile, unittest
from unittest.mock import patch
import native_integration as native
REPO=Path(__file__).resolve().parents[1];SKILL=REPO/'skills/mql5-coding'
class NativeEvidence(unittest.TestCase):
 def setUp(self):
  self.nonce='a'*32
  self.run={'status':'application_marker_passed','inputs':{'expected_log_marker_sha256':[hashlib.sha256(('MQL5_CODING_PASS:'+self.nonce+':toolkit-selftest').encode()).hexdigest()]},'evidence':{'checks':{'expected_markers_matched':True}},'process':{**{k:True for k in ('execution_attempted','process_created','resumed','job_empty_verified','post_exit_no_matching_terminal','post_exit_no_potential_descendants')},'exit_code':0},'cleanup':{'errors':[]}}
  self.journal={'status':'completed','truncated':False,'evidence_status':'complete_segments','groups':[{'message':'MQL5_TEST_COUNTS:checked=11,failed=0','count':1}]}
  self.report={'parsing':{'status':'success'},'evidence_linkage':{'status':'hash_verified'},'recorded_run':{'status':'application_marker_passed'},'metrics':{name:{'state':'finite','value':'0'} for name in ('trades','deals')}}
 def verify(self):native.verify_native_evidence(self.run,self.journal,self.report,self.nonce)
 def test_independent_fixture(self):self.assertEqual(native.verify_fixture(SKILL)['assertions'],11)
 def test_complete_evidence(self):self.verify()
 def test_engine_only(self):self.run['status']='engine_smoke_passed';self.assertRaises(native.GateFailure,self.verify)
 def test_cleanup_checks(self):
  for key in ('execution_attempted','process_created','resumed','job_empty_verified','post_exit_no_matching_terminal','post_exit_no_potential_descendants'):
   with self.subTest(key=key):self.run['process'][key]=False;self.assertRaises(native.GateFailure,self.verify);self.run['process'][key]=True
 def test_unique_marker(self):self.run['inputs']['expected_log_marker_sha256']=['0'*64];self.assertRaises(native.GateFailure,self.verify)
 def test_cleanup_error(self):self.run['cleanup']['errors']=['remaining child'];self.assertRaises(native.GateFailure,self.verify)
 def test_process_exit(self):self.run['process']['exit_code']=7;self.assertRaises(native.GateFailure,self.verify)
 def test_bad_assertions(self):
  for text in ('MQL5_TEST_COUNTS:checked=10,failed=0','MQL5_TEST_COUNTS:checked=11,failed=1','MQL5_TEST_FAIL:boundary'):
   self.journal['groups']=[{'message':text,'count':1}];self.assertRaises(native.GateFailure,self.verify)
 def test_duplicate_counts(self):self.journal['groups'][0]['count']=2;self.assertRaises(native.GateFailure,self.verify)
 def test_partial_journals(self):
  self.journal['truncated']=True;self.assertRaises(native.GateFailure,self.verify);self.journal['truncated']=False;self.journal['evidence_status']='partial_segments';self.assertRaises(native.GateFailure,self.verify)
 def test_stale_report(self):self.report['evidence_linkage']['status']='mismatch';self.assertRaises(native.GateFailure,self.verify)
 def test_trades_and_deals(self):
  for name in ('trades','deals'):
   for value in ({'state':'finite','value':'1'},{'state':'missing','value':None},{'state':'undefined','value':None}):self.report['metrics'][name]=value;self.assertRaises(native.GateFailure,self.verify)
   self.report['metrics'][name]={'state':'finite','value':'0'}
 def test_marker_redaction(self):self.journal['groups'].append({'message':self.nonce,'count':1});self.assertRaises(native.GateFailure,self.verify)
 def test_input_nonce_redaction_preserves_evidence_and_marker_gate(self):
  self.journal['segments']=[{'sha256':hashlib.sha256(b'journal fixture').hexdigest(),'source_offset':2,'byte_length':42}]
  self.journal['groups'].append({'message':'TestNonce='+self.nonce,'representative_excerpt':'TestNonce='+self.nonce,'count':1})
  original=json.loads(json.dumps(self.journal));redacted,count=native.redact_fixture_nonce(self.journal,self.nonce)
  self.assertEqual(self.journal,original);self.assertEqual(count,2);self.assertEqual(redacted['segments'],original['segments'])
  self.assertEqual(redacted['groups'][-1]['count'],1);self.assertIn('<TEST_NONCE>',redacted['groups'][-1]['message'])
  self.journal=redacted;self.verify()
  self.journal['groups'].append({'message':'MQL5_CODING_PASS:'+self.nonce+':toolkit-selftest','count':1})
  self.journal,_=native.redact_fixture_nonce(self.journal,self.nonce);self.assertRaises(native.GateFailure,self.verify)
 def test_existing_root_rejected(self):
  with tempfile.TemporaryDirectory() as temp:
   p=Path(temp);self.assertRaises(native.GateFailure,native.prepare_terminal,p,p,p,SKILL)
 def test_changed_fixture(self):
  with tempfile.TemporaryDirectory() as temp:
   p=Path(temp);shutil.copytree(SKILL/'assets',p/'assets');ea=p/'assets/Mql5ToolkitSelfTest.mq5';original=ea.read_text()
   for changed in (original.replace('ClampExample(-9)== -2','ClampExample(-9)== -1'),original+'\nvoid Bad(){ OrderSend(r,s); }',original.replace('return(-2);','return(-1);')):ea.write_text(changed);self.assertRaises(native.GateFailure,native.verify_fixture,p)
class DelegateFailures(unittest.TestCase):
 def test_incomplete_and_unclean_delegation_is_not_success(self):
  for status,cleanup,size in [('timed_out',True,10),('launch_failed',True,10),('completed',False,10),('completed',True,16777217)]:
   with self.subTest(status=status,cleanup=cleanup,size=size),tempfile.TemporaryDirectory() as temporary:
    root=Path(temporary)
    def runner(command,work,out,err,**kwargs):
     out.write_text('');err.write_text('');return {'status':status,'cleanup_verified':cleanup,'console_bytes':size,'exit_code':0}
    with patch.object(native,'run_owned',side_effect=runner):self.assertRaises(native.GateFailure,native.delegate,Path('C:/pwsh.exe'),Path('C:/script.ps1'),{},root,'probe')
    self.assertTrue((root/'probe-process.json').is_file())
 def test_native_module_path_is_child_local(self):
  before=dict(os.environ);env=native.host_env(Path('C:/Windows/powershell.exe'))
  self.assertEqual(dict(os.environ),before);self.assertIn('WindowsPowerShell',env['PSModulePath']);self.assertNotIn('PowerShell/7',env['PSModulePath'])

@unittest.skipUnless(os.name=='nt','Windows path and reparse semantics')
class OrdinaryPaths(unittest.TestCase):
 def test_ordinary_normal_path_is_preserved(self):
  with tempfile.TemporaryDirectory(prefix='m5-native-path-',dir='C:/') as temporary:
   root=Path(temporary)
   self.assertEqual(native.ordinary(root),root)
   self.assertEqual(native.ordinary(root/'fresh'),root/'fresh')
 def test_parent_selector_is_normalized_before_identity_derivation(self):
  with tempfile.TemporaryDirectory(prefix='m5-native-path-',dir='C:/') as temporary:
   base=Path(temporary);(base/'selector').mkdir()
   selected=base/'selector'/'..'/'fresh'
   self.assertEqual(native.ordinary(selected),base/'fresh')
 def test_missing_ordinary_ancestry_remains_supported(self):
  with tempfile.TemporaryDirectory(prefix='m5-native-path-',dir='C:/') as temporary:
   selected=Path(temporary)/'missing-parent'/'fresh'
   self.assertEqual(native.ordinary(selected),selected)
 def test_dangling_reparse_ancestor_is_rejected_before_normalization(self):
  with tempfile.TemporaryDirectory(prefix='m5-native-path-',dir='C:/') as temporary:
   base=Path(temporary);target=base/'target';target.mkdir();junction=base/'junction'
   command=[str(Path(os.environ['SystemRoot'])/'System32/cmd.exe'),'/d','/c','mklink','/J',str(junction),str(target)]
   process=native.run_owned(command,base,base/'junction.stdout',base/'junction.stderr',seconds=30)
   self.assertEqual(process['exit_code'],0);self.assertTrue(process['cleanup_verified'])
   # Both paths are task-owned. The junction remains observable after its
   # target is removed, even though exists() is false for the junction.
   self.assertTrue(target.resolve().is_relative_to(base.resolve()));target.rmdir()
   self.assertFalse(junction.exists());self.assertTrue(junction.lstat().st_file_attributes & 0x400)
   self.assertRaises(native.GateFailure,native.ordinary,junction/'..'/'fresh')
 def test_normalization_does_not_hide_original_reparse_ancestor(self):
  with tempfile.TemporaryDirectory(prefix='m5-native-path-',dir='C:/') as temporary:
   base=Path(temporary);unsafe=base/'reparse-ancestor';unsafe.mkdir()
   original=Path.lstat;inspected=[]
   def metadata(path,*args,**kwargs):
    inspected.append(path)
    if path==unsafe:return SimpleNamespace(st_file_attributes=0x400)
    return original(path,*args,**kwargs)
   # Only the filesystem attribute is simulated. The original selector,
   # ancestry traversal, normalization and refusal remain production logic.
   with patch.object(Path,'lstat',metadata):
    self.assertRaises(native.GateFailure,native.ordinary,unsafe/'..'/'fresh')
   self.assertIn(unsafe,inspected)
 def test_terminal_data_identity_uses_canonical_installation_path(self):
  with tempfile.TemporaryDirectory(prefix='m5-native-path-',dir='C:/') as temporary:
   base=Path(temporary);platform=base/'platform';platform.mkdir();(base/'selector').mkdir()
   for name in ('MetaEditor64.exe','terminal64.exe','metatester64.exe'):(platform/name).write_bytes(b'Not executable: copied identity fixture')
   cache=base/'cache';history=cache/'bases/MetaQuotes-Demo/history/EURUSD';history.mkdir(parents=True)
   (history/'2025.hcc').write_bytes(b'Non-native history identity fixture')
   application_data=base/'application-data';application_data.mkdir()
   canonical_root=base/'run';canonical_install=canonical_root/'terminal'
   expected=hashlib.md5(str(canonical_install).upper().encode('utf-16le')).hexdigest().upper()
   with patch.dict(os.environ,{'APPDATA':str(application_data)}):
    root,install,data,project,copied=native.prepare_terminal(platform,cache,base/'selector'/'..'/'run',SKILL)
   self.assertEqual(root,canonical_root);self.assertEqual(install,canonical_install)
   self.assertEqual(data,application_data/'MetaQuotes/Terminal'/expected)
   self.assertEqual(project,canonical_root/'project');self.assertEqual(len(copied),6)
   self.assertEqual((data/'origin.txt').read_text(encoding='utf-16'),str(canonical_install))
   self.assertEqual(list((application_data/'MetaQuotes/Terminal').iterdir()),[data])

@unittest.skipUnless(os.name=='nt','Windows test doubles')
class SyntheticOrchestration(unittest.TestCase):
 def test_complete_chain_both_hosts(self):
  with tempfile.TemporaryDirectory(prefix='m5-native-synthetic-',dir='C:/') as temporary:
   base=Path(temporary);binaries=base/'binaries';binaries.mkdir();metadata=base/'metadata.cs';metadata.write_text('using System.Reflection;[assembly:AssemblyFileVersion("5.0.0.1234")]')
   compiler=Path(os.environ['WINDIR'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
   subprocess.run([str(compiler),'/nologo','/out:'+str(binaries/'MetaEditor64.exe'),str(REPO/'tests/FakeMetaEditor.cs')],capture_output=True,check=True)
   source=(REPO/'tests/FakeTerminal.cs').read_text().replace('string marker = Environment.GetEnvironmentVariable("FAKE_MT5_MARKER") ?? "";', '''string preset = File.ReadAllText(Path.Combine(dataPath,"MQL5","Profiles","Tester",config["ExpertParameters"]),Encoding.Unicode);
        string nonce = System.Text.RegularExpressions.Regex.Match(preset,@"TestNonce=([0-9a-f]{32})").Groups[1].Value;
        string marker = "MQL5_CODING_PASS:"+nonce+":toolkit-selftest";''').replace('ApplicationLine(config, marker),','ApplicationLine(config, "TestNonce="+nonce),\n                ApplicationLine(config, "MQL5_TEST_COUNTS:checked=11,failed=0"),\n                ApplicationLine(config, marker),')
   source=source.replace('string configPath = ConfigPath(args);','File.AppendAllText(Environment.GetEnvironmentVariable("FAKE_NATIVE_LAUNCH_WITNESS"),"launched\\n"); string configPath = ConfigPath(args);')
   terminal=base/'terminal.cs';terminal.write_text(source);subprocess.run([str(compiler),'/nologo','/out:'+str(binaries/'terminal64.exe'),str(terminal),str(metadata)],capture_output=True,check=True)
   for host in (Path(os.environ['ProgramFiles'])/'PowerShell/7/pwsh.exe',Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/powershell.exe'):
    if not host.is_file():continue
    with self.subTest(host=str(host)):
     root=base/host.stem;root.mkdir();install=root/'install';install.mkdir();data=root/'data';data.mkdir();project=root/'project';project.mkdir()
     for name in ('MetaEditor64.exe','terminal64.exe'):shutil.copy2(binaries/name,install/name)
     for name in ('Mql5ToolkitSelfTest.mq5','Mql5Assertions.mqh'):shutil.copy2(SKILL/'assets'/name,project/name)
     for d in ('MQL5/Experts','MQL5/Profiles/Tester','Tester/logs','logs'):(data/d).mkdir(parents=True)
     (data/'origin.txt').write_text(str(install),encoding='utf-16')
     args=SimpleNamespace(platform_root=binaries,cache_root=base,run_root=root,skill_root=SKILL,powershell=host,python=Path(sys.executable),timeout_seconds=30);record={'status':'failed'}
     with patch.object(native,'prepare_terminal',return_value=(root,install,data,project,[])),patch.dict(os.environ,{'FAKE_MT5_MODE':'pass','FAKE_MT5_REPORT_FIXTURE':str(REPO/'tests/fixtures/reports/no-trades.htm'),'FAKE_NATIVE_LAUNCH_WITNESS':str(root/'terminal-launch-witness.txt')}):
      try:native.execute(args,record)
      except Exception as error:
       target=os.environ.get('MQL5_NATIVE_TEST_EVIDENCE')
       if target:shutil.copytree(root,Path(target)/('synthetic-'+host.stem+'-'+__import__('uuid').uuid4().hex))
       diagnostic='\n'.join(p.name+': '+p.read_text(encoding='utf-8-sig')[-6000:] for p in root.glob('changed-header.*.txt'))
       raise AssertionError(str(error)+'\n'+diagnostic) from error
     self.assertEqual(record['status'],'passed');self.assertEqual(record['changed_header_rejection']['exit_code'],2);self.assertEqual((root/'terminal-launch-witness.txt').read_text().splitlines(),['launched'])
if __name__=='__main__':unittest.main()
