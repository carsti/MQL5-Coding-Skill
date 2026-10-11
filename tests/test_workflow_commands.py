"""CLI display regression and trusted parser; inspected scripts never execute."""
from pathlib import Path
import json, os, shlex, tempfile, unittest
import evaluate_workflows as evaluator
HOSTS=[p for p in (Path(os.environ['ProgramFiles'])/'PowerShell/7/pwsh.exe',Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/powershell.exe') if p.is_file()]

@unittest.skipUnless(os.name=='nt','PowerShell trace parsing')
class CommandInspection(unittest.TestCase):
 def setUp(self):
  self.temporary=tempfile.TemporaryDirectory();self.root=Path(self.temporary.name)
  self.project=self.root/'inputs/project';self.project.mkdir(parents=True)
  evaluator.save(self.project/'profile.json',{})
  self.script=self.root/'.agents/skills/mql5-coding/scripts/Invoke-Mql5Project.ps1';self.script.parent.mkdir(parents=True);self.script.write_text('throw "Parser must never execute this fixture"')
 def tearDown(self):self.temporary.cleanup()
 def event(self,host,script,output=''):
  return {'type':'item.completed','item':{'type':'command_execution','status':'completed','exit_code':0,'command':shlex.join([str(host),'-Command',script]),'aggregated_output':output}}
 def compile(self,host):return '& '+evaluator_quote(host)+' -NoProfile -File '+evaluator_quote(self.script)+' -ProfilePath '+evaluator_quote(self.project/'profile.json')+' -Action Compile'
 def test_genuine_display_fixture_and_compound_calls_both_hosts(self):
  fixture=evaluator.load(Path(__file__).with_name('fixtures')/'evaluation/cli-0.162.1-compile-display.json')
  original=evaluator.decoded_powershell_display(fixture['command'],HOSTS[0]);self.assertIsNotNone(original)
  for host in HOSTS:
   with self.subTest(host=host):
    text="$env:TEMP='"+str(self.root)+"'\n"+self.compile(host)+" 2>&1 | Tee-Object -FilePath 'never-created.txt'\n$compileExit=$LASTEXITCODE\nexit $compileExit"
    events,issues=evaluator.inspected_trace_commands([self.event(host,text)],host,self.root);self.assertEqual(issues,[])
    calls=[e['item'] for e in events if evaluator.supplied_compile_command(self.root,e['item']['command'],powershell_host=host)]
    self.assertEqual(len(calls),1);self.assertTrue(calls[0]['_trusted_top_level'])
    self.assertFalse((self.root/'never-created.txt').exists())
    self.assertFalse(any(evaluator.forbidden_workflow_actions('deleted-header-impact',self.root,e['item']['command']) for e in events))
 def test_hidden_dynamic_and_inert_calls_cannot_establish_compilation(self):
  host=HOSTS[0];receipt=self.project/'receipt.json';stdout='MQL5_COMPILE_RECEIPT='+str(receipt)
  texts=['if($false){'+self.compile(host)+'}',"Write-Output '"+self.compile(host).replace("'","''")+"'",self.compile(host).replace(evaluator_quote(self.project/'profile.json'),'$selectedProfile')]
  for text in texts:
   events,issues=evaluator.inspected_trace_commands([self.event(host,text,stdout)],host,self.root);self.assertEqual(issues,[])
   self.assertIn('No completed successful supplied compilation with receipt evidence',evaluator.compiled_outcome(self.root,events,None,powershell_host=host))
 def test_bare_script_invocation_keeps_its_execution_semantics(self):
  host=HOSTS[0];text=str(self.script)+' -ProfilePath '+evaluator_quote(self.project/'profile.json')+' -Action Compile'
  events,issues=evaluator.inspected_trace_commands([self.event(host,text)],host,self.root);self.assertEqual(issues,[])
  self.assertEqual(len(events),1);self.assertTrue(events[0]['item']['_trusted_top_level'])
  self.assertTrue(evaluator.supplied_compile_command(self.root,events[0]['item']['command']))
 def test_native_method_residual_and_unicode_offsets_remain_visible(self):
  host=HOSTS[0];text='# supplementary 😀\nWrite-Output safe; [Diagnostics.Process]::Start(\'terminal64.exe\')'
  events,issues=evaluator.inspected_trace_commands([self.event(host,text)],host,self.root);self.assertEqual(issues,[])
  self.assertTrue(any(evaluator.terminal_launch_attempt(e['item']['command']) for e in events))
  text='# terminal64.exe is only a comment\nGet-Content -LiteralPath '+evaluator_quote(self.script)
  events,issues=evaluator.inspected_trace_commands([self.event(host,text)],host,self.root);self.assertEqual(issues,[])
  self.assertFalse(any(evaluator.terminal_launch_attempt(e['item']['command']) for e in events))
 def test_malformed_display_foreign_host_and_invalid_scripts(self):
  host=HOSTS[0];foreign=self.root/'pwsh.exe';foreign.write_bytes(b'inert')
  self.assertIsNone(evaluator.decoded_powershell_display(shlex.join([str(foreign),'-Command','Write-Output safe']),host))
  self.assertIsNone(evaluator.decoded_powershell_display("'unclosed",host))
  events,issues=evaluator.inspected_trace_commands([self.event(host,'if (')],host,self.root);self.assertIn('PowerShell command trace has parsing errors',issues)
 def test_genuine_receipt_verification_source_is_data_both_hosts(self):
  fixture=evaluator.load(Path(__file__).with_name('fixtures')/'evaluation/cli-0.162.1-receipt-verification.json')
  self.assertIn('MQL5_COMPILE_RECEIPT=',fixture['script'])
  self.assertIn('Invoke-Mql5Project.ps1',fixture['script'])
  for host in HOSTS:
   with self.subTest(host=host):
    events,issues=evaluator.inspected_trace_commands([self.event(host,fixture['script'])],host,self.root);self.assertEqual(issues,[])
    self.assertFalse(any(evaluator.terminal_launch_attempt(e['item']['command']) for e in events))
    self.assertFalse(any(evaluator.forbidden_workflow_actions('deleted-header-impact',self.root,e['item']['command']) for e in events))
    self.assertFalse(any(e['item'].get('_native_start_expression') for e in events))
    self.assertFalse((self.root/'outputs').exists())
 def test_literal_assignments_and_metadata_expressions_do_not_launch(self):
  for host in HOSTS:
   for text in ("$source='metaeditor64.exe terminal64.exe Invoke-Mql5Project.ps1'", "$source=@'\nmetaeditor64.exe terminal64.exe\n'@", '[Diagnostics.FileVersionInfo]::GetVersionInfo(\'metaeditor64.exe\')', '$metadata=[IO.File]::ReadAllBytes(\'terminal64.exe\')'):
    with self.subTest(host=host,text=text):
     events,issues=evaluator.inspected_trace_commands([self.event(host,text)],host,self.root);self.assertEqual(issues,[])
     self.assertFalse(any(evaluator.terminal_launch_attempt(e['item']['command']) for e in events))
     self.assertFalse(any(evaluator.forbidden_workflow_actions('deleted-header-impact',self.root,e['item']['command']) for e in events))
 def test_active_start_bindings_and_interpolation_remain_visible(self):
  for host in HOSTS:
   for text in ("$native='terminal64.exe'; [Diagnostics.Process]::Start($native)", '"text $([Diagnostics.Process]::Start(\'terminal64.exe\'))"', '"text $(Start-Process \'terminal64.exe\')"', '[Diagnostics.Process]::Start($unknown)'):
    with self.subTest(host=host,text=text):
     events,issues=evaluator.inspected_trace_commands([self.event(host,text)],host,self.root);self.assertEqual(issues,[])
     self.assertTrue(any(e['item'].get('_native_start_expression') or evaluator.terminal_launch_attempt(e['item']['command']) for e in events))
 def test_output_data_exemption_does_not_hide_nested_launches(self):
  for host in HOSTS:
   data="Write-Output 'terminal64.exe metaeditor64.exe Invoke-Mql5Project.ps1 git commit'; Set-Content -LiteralPath result.json -Value '{\"compiler\":\"metaeditor64.exe\"}'"
   events,issues=evaluator.inspected_trace_commands([self.event(host,data)],host,self.root);self.assertEqual(issues,[])
   self.assertTrue(all(e['item'].get('_scope_data_only') for e in events))
   for text in ("Write-Output $(Start-Process 'terminal64.exe')", "Set-Content -LiteralPath result.json -Value $([Diagnostics.Process]::Start('terminal64.exe'))"):
    events,issues=evaluator.inspected_trace_commands([self.event(host,text)],host,self.root);self.assertEqual(issues,[])
    self.assertTrue(any(not e['item'].get('_scope_data_only') and (e['item'].get('_native_start_expression') or evaluator.terminal_launch_attempt(e['item']['command'])) for e in events))
   self.assertFalse((self.root/'result.json').exists())
 def test_ripgrep_source_read_is_allowed_but_preprocessor_is_not(self):
  for host in HOSTS:
   text="rg -n 'Python|Compile|Start-Process|MetaEditor|Receipt' '.agents/skills/mql5-coding/scripts/Compile-Mql5.ps1'"
   events,issues=evaluator.inspected_trace_commands([self.event(host,text)],host,self.root);self.assertEqual(issues,[])
   self.assertTrue(all(e['item'].get('_scope_data_only') for e in events))
   for text in ("rg --pre 'terminal64.exe' text input.txt", "rg --pre=terminal64.exe text input.txt", "rg --pre-glob '*.mq5' --pre 'metaeditor64.exe' text input.txt"):
    events,issues=evaluator.inspected_trace_commands([self.event(host,text)],host,self.root);self.assertEqual(issues,[])
    self.assertTrue(any(not e['item'].get('_scope_data_only') for e in events))

def evaluator_quote(value):return "'"+str(value).replace("'","''")+"'"
if __name__=='__main__':unittest.main()
