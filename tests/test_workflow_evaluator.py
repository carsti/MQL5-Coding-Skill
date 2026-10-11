"""Independent scorer and bounded process tests; no model credentials required."""
import json
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from evaluate_workflows import REPO, SCHEMA, compiled_outcome, evaluate_assertions, evaluate_calculation, forbidden_workflow_actions, grade, inventory, normalize_trace, prepare, ps, read_trace, save, staged_skill_issues, supplied_compile_command, terminal_launch_attempt, trace_summary, verify_workflow_receipts
from workflow_process import run_owned

class Scoring(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        (self.root/'inputs').mkdir();(self.root/'outputs').mkdir()
        self.final={'case_id':'scenario-validation','status':'completed','findings':[{'code':'validated','detail':'Whole configuration checked'}],'evidence':['outputs/validation/result.json'],'limitations':[]}
        self.events=[{'type':'item.completed','item':{'type':'command_execution','command':'Invoke-Mql5ScenarioBatch.ps1 -Action Validate'}}]
        (self.root/'outputs/validation').mkdir();save(self.root/'outputs/validation/result.json',{'status':'validated','action':'Validate'})
    def tearDown(self):self.temp.cleanup()
    def documented(self):
        source='b6b3338a985e1efedc2c87fa478f648d7de53e1daa6d2a8a9e5359b8878e23fa';topic='mql5:02ce7771459932284a2d93ac'
        citation={'source_file':'mql5.chm','topic_id':topic,'source_revision':source,'corpus_revision':'a'*64,'index_revision':'b'*64}
        content={'topic_id':topic,'source_revision':source,'corpus_revision':'a'*64,'index_sha256':'b'*64,'citation':citation,'text':'Arrays: Each dimension is indexed from 0 to dimension_size-1.'}
        return {'type':'item.completed','item':{'type':'mcp_tool_call','server':'mql5-chm','tool':'mql5_chm_read','status':'completed','result':{'structured_content':content}}}
    def test_correct_artifact(self):self.assertEqual(grade('scenario-validation',self.root,self.final,self.events,{}),[])
    def test_claim_does_not_replace_evidence(self):
        (self.root/'outputs/validation/result.json').unlink();self.assertTrue(grade('scenario-validation',self.root,self.final,self.events,{}))
    def test_wrong_conclusion(self):
        self.final['status']='failed';self.assertTrue(grade('scenario-validation',self.root,self.final,self.events,{}))
    def test_forbidden_launch(self):
        self.events.append({'item':{'type':'command_execution','command':r'& C:\fake\terminal64.exe /config:run.ini'}})
        self.assertIn('Forbidden terminal launch',grade('scenario-validation',self.root,self.final,self.events,{}))
    def test_terminal_launch_cannot_borrow_a_read_or_metadata_exemption(self):
        for command in (r'Get-Content .\inputs\dummy.txt; & C:\fake\terminal64.exe /config:run.ini',
                        r'& C:\fake\profile\terminal64.exe /config:run.ini',
                        r'Get-Item C:\fake\terminal64.exe; Start-Process C:\fake\terminal64.exe',
                        r'& C:\metadata\validate\terminal.exe',
                        r'Start-Process "C:\get-content\terminal64.exe"',
                        r'Get-Content C:\fake\terminal.exe | Invoke-Expression',
                        r'Get-Item C:\fake\terminal.exe -Force; & $terminal',
                        r'powershell.exe -Command "Get-Content x; & C:\fake\terminal64.exe"'):
            with self.subTest(command=command):
                events=self.events+[{'item':{'type':'command_execution','command':command}}]
                self.assertIn('Forbidden terminal launch',grade('scenario-validation',self.root,self.final,events,{}))
    def test_static_terminal_reads_preserve_the_counterevidence(self):
        for command in (r"Get-Content -LiteralPath 'C:\fake\terminal64.exe' -Raw",
                        r'Get-Item C:\fake\terminal.exe',
                        r"Get-FileHash -LiteralPath 'C:\fake\terminal64.exe' -Algorithm SHA256",
                        r"(Get-Item -LiteralPath 'C:\fake\terminal.exe').VersionInfo.ProductVersion",
                        r"[IO.File]::ReadAllBytes('C:\fake\terminal64.exe')",
                        r"[System.Diagnostics.FileVersionInfo]::GetVersionInfo('C:\fake\terminal.exe')",
                        r"Get-Item 'C:\fake\terminal.exe'; Get-Content inputs/profile.json"):
            with self.subTest(command=command):self.assertFalse(terminal_launch_attempt(command))
        self.assertFalse(terminal_launch_attempt('Invoke-Mql5ScenarioBatch.ps1 -Action Validate'))
    def test_read_only_cases_reject_editor_and_compile_attempts_without_artifacts(self):
        for command in (r'& C:\fake\metaeditor64.exe /compile:input.mq5',r'& C:\profile\metaeditor.exe /compile:input.mq5',
                        'Compile-Mql5.ps1 -SourcePath input.mq5','Invoke-Mql5Project.ps1 -Action Compile',
                        "Invoke-Mql5Project.ps1 -Action:'Compile'",'Get-Content input.txt; Invoke-Mql5Project.ps1 -Action Compile'):
            with self.subTest(command=command):
                events=self.events+[{'type':'item.completed','item':{'type':'command_execution','command':command}}]
                self.assertIn('Forbidden compiler launch',grade('scenario-validation',self.root,self.final,events,{}))
                for case in ('standalone-source-review','isolated-behavior-tests','report-comparison','journal-grouping','profile-without-conditions'):
                    self.assertIn('Forbidden compiler launch',forbidden_workflow_actions(case,self.root,command))
    def test_tester_actions_are_forbidden_in_all_evaluation_cases(self):
        for case in ('scenario-validation','standalone-source-review','isolated-behavior-tests','deleted-header-impact'):
            for command in ('Invoke-Mt5TesterSmoke.ps1 -Execute','Invoke-Mql5Project.ps1 -Action TesterSmoke',
                            'Invoke-Mql5Project.ps1 -Action TesterPreflight','Invoke-Mql5ScenarioBatch.ps1 -Action Execute'):
                with self.subTest(case=case,command=command):self.assertIn('Forbidden tester workflow',forbidden_workflow_actions(case,self.root,command))
    def test_metadata_reads_and_default_validation_remain_allowed(self):
        for command in (r"(Get-Item 'C:\fake\metaeditor64.exe').VersionInfo.ProductVersion",
                        r'Get-FileHash C:\fake\metaeditor.exe -Algorithm SHA256',
                        'Get-Content Compile-Mql5.ps1 -Raw','Get-Content Invoke-Mt5TesterSmoke.ps1',
                        'Invoke-Mql5Project.ps1 -Action Validate','Invoke-Mql5Project.ps1 -ProfilePath inputs/profile.json',
                        'Invoke-Mql5ScenarioBatch.ps1 -Action Validate','Invoke-Mql5ScenarioBatch.ps1 -ManifestPath inputs/scenarios.json'):
            with self.subTest(command=command):self.assertEqual(forbidden_workflow_actions('scenario-validation',self.root,command),[])
    def test_include_impact_retains_only_its_synthetic_compile_exception(self):
        install=self.root/'inputs/synthetic-install';install.mkdir();editor=install/'metaeditor64.exe';editor.write_bytes(b'synthetic fixture; never executed')
        project=self.root/'inputs/project';project.mkdir();profile=project/'profile.json';profile.write_text('{}')
        for command in ('Invoke-Mql5Project.ps1 -ProfilePath inputs/project/profile.json -Action Compile',
                        'Invoke-Mql5Project.ps1 -ProfilePath "'+str(profile)+'" -Action Compile',
                        "Invoke-Mql5Project.ps1 -ProfilePath:'inputs/project/profile.json' -Action Compile",
                        'Compile-Mql5.ps1 -SourcePath inputs/project/A.mq5 -MetaEditorPath "'+str(editor)+'"',
                        '& "'+str(editor)+'" /compile:inputs/project/A.mq5',
                        '& inputs/synthetic-install/metaeditor64.exe /compile:inputs/project/A.mq5'):
            with self.subTest(command=command):self.assertEqual(forbidden_workflow_actions('deleted-header-impact',self.root,command),[])
        for command in (r'& C:\native\metaeditor64.exe /compile:input.mq5',
                        'Compile-Mql5.ps1 -SourcePath inputs/project/A.mq5',
                        'Compile-Mql5.ps1 -SourcePath inputs/project/A.mq5 -MetaEditorPath $selected',
                        'Compile-Mql5.ps1 -MetaEditorPath "'+str(editor)+'"; Compile-Mql5.ps1 -SourcePath inputs/project/A.mq5',
                        '& "'+str(editor)+'" /compile:input.mq5; & C:\\native\\metaeditor64.exe',
                        '& "C:\\invalid\x00metaeditor64.exe" /compile:input.mq5'):
            with self.subTest(command=command):self.assertIn('Forbidden compiler launch',forbidden_workflow_actions('deleted-header-impact',self.root,command))
    def test_include_impact_compile_requires_one_literal_prepared_profile(self):
        project=self.root/'inputs/project';project.mkdir();profile=project/'profile.json';profile.write_text('{}')
        for command in (r'Invoke-Mql5Project.ps1 -ProfilePath C:\native\profile.json -Action Compile',
                        'Invoke-Mql5Project.ps1 -Action Compile',
                        'Invoke-Mql5Project.ps1 -ProfilePath $selected -Action Compile',
                        'Invoke-Mql5Project.ps1 -ProfilePath "'+str(profile)+'$suffix" -Action Compile',
                        'Invoke-Mql5Project.ps1 -ProfilePath "'+str(profile)+'"$suffix -Action Compile',
                        'Invoke-Mql5Project.ps1 -ProfilePath inputs/project/profile.json -ProfilePath inputs/project/profile.json -Action Compile',
                        'Invoke-Mql5Project.ps1 -ProfilePath inputs/project/profile.json -Prof C:/native/profile.json -Action Compile',
                        'Invoke-Mql5Project.ps1 -ProfilePath inputs/project/profile.json @params -Action Compile',
                        'Invoke-Mql5Project.ps1 -ProfilePath inputs/project/profile.json -Action Compile; Invoke-Mql5Project.ps1 -Action Compile'):
            with self.subTest(command=command):self.assertIn('Forbidden compiler launch',forbidden_workflow_actions('deleted-header-impact',self.root,command))
        for name in ('P','Pr','Pro','Prof','Profi','Profil','Profile','ProfileP','ProfilePa','ProfilePat'):
            command='Invoke-Mql5Project.ps1 -'+name+' inputs/project/profile.json -Action Compile'
            with self.subTest(name=name):self.assertIn('Forbidden compiler launch',forbidden_workflow_actions('deleted-header-impact',self.root,command))
        profile.unlink()
        self.assertIn('Forbidden compiler launch',forbidden_workflow_actions('deleted-header-impact',self.root,'Invoke-Mql5Project.ps1 -ProfilePath inputs/project/profile.json -Action Compile'))
    def test_uncertain_project_actions_fail_instead_of_supplying_a_validation_exemption(self):
        for command in ('Invoke-Mql5Project.ps1 -Action $selection','Invoke-Mql5Project.ps1 @params',
                        'Invoke-Mql5Project.ps1 -Act Compile','Invoke-Mql5Project.ps1 -Action Validate -Act Compile',
                        'Invoke-Mql5Project.ps1 -Action Validate -Action Compile'):
            with self.subTest(command=command):self.assertIn('Uncertain project execution action',forbidden_workflow_actions('scenario-validation',self.root,command))
    def test_missing_metrics_do_not_invent_evidence(self):self.assertEqual(grade('scenario-validation',self.root,self.final,self.events,{}),[])
    def test_schema_types(self):
        self.final['findings']=[{'code':3,'detail':'bad'}];self.assertTrue(grade('scenario-validation',self.root,self.final,self.events,{}))
    def test_input_mutation(self):self.assertTrue(grade('scenario-validation',self.root,self.final,self.events,{'x':'0'*64}))
    def test_selected_staged_skill_identity_and_child_only_bytecode_policy(self):
        staged=self.root/'.agents/skills/mql5-coding';(staged/'scripts').mkdir(parents=True)
        script=staged/'scripts/helper.py';script.write_text('value=1\n');wrapper=staged/'scripts/Invoke-Mql5Project.ps1';wrapper.write_text('# selected helper\n')
        before=inventory(staged)
        self.assertEqual(grade('scenario-validation',self.root,self.final,self.events,{},staged_before=before),[])
        # Ordinary module imports do not create caches with the child-local policy.
        prior=os.environ.get('PYTHONDONTWRITEBYTECODE')
        import_command=[sys.executable,'-c','import importlib.util,sys;s=importlib.util.spec_from_file_location("fixture",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);assert m.value==1',str(script)]
        subprocess.run(import_command,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},capture_output=True,check=True)
        self.assertEqual(os.environ.get('PYTHONDONTWRITEBYTECODE'),prior)
        self.assertFalse((staged/'scripts/__pycache__').exists())
        self.assertEqual(staged_skill_issues(staged,before),[])
        self.assertEqual(grade('scenario-validation',self.root,self.final,self.events,{},staged_before=before),[])
        # Explicit compilation creates executable bytecode and must fail closure.
        subprocess.run([sys.executable,'-I','-c','import py_compile,sys;py_compile.compile(sys.argv[1],doraise=True)',str(script)],capture_output=True,check=True)
        self.assertTrue(staged_skill_issues(staged,before))
        cached_before=inventory(staged)
        self.assertEqual(staged_skill_issues(staged,cached_before),[])
        self.assertEqual(grade('scenario-validation',self.root,self.final,self.events,{},staged_before=cached_before),[])
        for name in ('scripts/added.py','scripts/added.ps1','scripts/extra.txt','scripts/__pycache__/foreign.cpython-313.pyc','scripts/helper.pyc','scripts/__pycache__/helper.cpython-313.py'):
            addition=staged/name;addition.write_bytes(b'added evidence')
            try:
                with self.subTest(addition=name):self.assertTrue(staged_skill_issues(staged,before))
            finally:addition.unlink()
        wrapper.write_text('Write-Output fabricated\n')
        self.assertIn('Selected staged skill changed: scripts/Invoke-Mql5Project.ps1',grade('scenario-validation',self.root,self.final,self.events,{},staged_before=cached_before))
        wrapper.unlink();self.assertIn('Selected staged skill changed: scripts/Invoke-Mql5Project.ps1',staged_skill_issues(staged,before))
        # Baseline/candidate copies protect their own bytes, not the other arm's.
        wrapper.write_text('# alternate selected baseline\n');alternate=inventory(staged)
        self.assertEqual(staged_skill_issues(staged,alternate),[])
        self.assertTrue(staged_skill_issues(staged,before))
        cache=next((staged/'scripts/__pycache__').glob('*.pyc'));cache.write_bytes(b'changed original cache')
        self.assertTrue(staged_skill_issues(staged,alternate))
    def test_malformed_trace(self):
        p=self.root/'trace';p.write_text('{}\n[]\ninvalid\n');events,issues=read_trace(p);self.assertEqual(len(events),1);self.assertEqual(len(issues),2)
    def test_unicode_separators_inside_json_strings_preserve_grade_and_metrics(self):
        event={**self.events[0],'item':{**self.events[0]['item'],'aggregated_output':'first\u0085second\u2028third\u2029fourth'}}
        usage={'type':'turn.completed','usage':{'input_tokens':2,'output_tokens':1}}
        expected=[event,usage]
        for newline in ('\n','\r\n','\r'):
            with self.subTest(newline=repr(newline)):
                path=self.root/'trace';path.write_bytes((newline.join(json.dumps(e,ensure_ascii=False) for e in expected)+newline).encode('utf-8'))
                events,issues=read_trace(path)
                self.assertEqual(issues,[]);self.assertEqual(events,expected)
                self.assertEqual(grade('scenario-validation',self.root,self.final,events,{}),[])
                summary=trace_summary(events);self.assertEqual(summary['issues'],[])
                self.assertEqual(len(summary['commands']),1);self.assertEqual(summary['usage'],usage['usage'])
    def test_escaped_controls_and_unicode_remain_distinct_from_malformed_lines(self):
        event={**self.events[0],'item':{**self.events[0]['item'],'aggregated_output':'escaped\n\r\t\v\f\u0085\u2028\u2029'}}
        path=self.root/'trace';path.write_bytes((json.dumps(event,ensure_ascii=True)+'\ninvalid\n').encode('utf-8'))
        events,issues=read_trace(path);self.assertEqual(events,[event]);self.assertEqual(issues,['Malformed JSONL event 2'])
    def test_malformed_item_is_failed_evidence(self):
        self.assertTrue(grade('scenario-validation',self.root,self.final,[{'item':'invalid'}],{}))
    def test_malformed_items_cannot_crash_post_grade_metrics(self):
        malformed=[{'item':value} for value in ('invalid',[],0,False,None)]
        malformed += [{'item':{'type':3}}]+[{'item':{'type':'command_execution','command':value}} for value in (None,{},[],3,'','   ')]
        events=self.events+malformed+[{'type':'turn.completed','usage':{'input_tokens':2}},{'type':'error'}]
        issues=grade('scenario-validation',self.root,self.final,events,{})
        self.assertIn('Malformed trace item',issues)
        summary=trace_summary(events)
        self.assertEqual(len(summary['commands']),1);self.assertEqual(summary['usage'],{'input_tokens':2})
        self.assertTrue(summary['execution_error']);self.assertEqual(len(summary['issues']),len(malformed))
        # Exercise the post-grade score construction used by main: invalid command
        # values never reach hashing/retry metrics or suppress retained failed scores.
        command_text=[c['command'] for c in summary['commands']]
        score={'status':'failed' if issues else 'passed','issues':issues,'commands':len(command_text),'repeated_identical_commands':len(command_text)-len(set(command_text))}
        save(self.root/'score.json',score);self.assertEqual(json.loads((self.root/'score.json').read_text())['status'],'failed')
    def test_read_trace_normalizes_all_items_before_consumers(self):
        events=[{'item':'invalid'},{'item':False},self.events[0],{'type':'turn.completed','usage':[1]}]
        path=self.root/'trace';path.write_text('\n'.join(json.dumps(e) for e in events))
        parsed,issues=read_trace(path);self.assertEqual(len(issues),2)
        self.assertEqual(len(parsed),2);summary=trace_summary(parsed)
        self.assertIsNone(summary['usage']);self.assertEqual(summary['issues'],['Malformed trace usage'])
        self.assertEqual(len(summary['commands']),1)
    def test_normalizer_preserves_legitimate_nested_values(self):
        events=[{'type':'item.completed','item':{'type':'mcp_tool_call','arguments':{'queries':['a','b']}}},{'type':'turn.completed','usage':None}]
        self.assertEqual(normalize_trace(events),(events,[]));self.assertEqual(trace_summary(events)['issues'],[])
    def test_unserializable_trace_metrics_are_failed_and_scores_still_publish(self):
        for value in ('\ud800',float('nan'),float('inf')):
            with self.subTest(value=ascii(value)):
                summary=trace_summary(self.events+[{'type':'turn.completed','usage':{'metric':value}}])
                self.assertEqual(summary['issues'],['Invalid serialized trace event']);self.assertIsNone(summary['usage'])
                save(self.root/'score.json',summary);self.assertTrue((self.root/'score.json').read_text())
    def test_deeply_nested_trace_is_failed_evidence(self):
        path=self.root/'trace';path.write_text('{"usage":'+'['*100000+'0'+']'*100000+'}\n')
        events,issues=read_trace(path);self.assertEqual(len(events),0);self.assertEqual(issues,['Malformed JSONL event 1'])
    def test_every_case_requires_its_independent_artifact(self):
        for case in ('report-comparison','deleted-header-impact','journal-grouping','standalone-source-review','profile-without-conditions','isolated-behavior-tests'):
            final={**self.final,'case_id':case,'limitations':['Not executed natively']}
            self.assertTrue(grade(case,self.root,final,[],{}),case)
    def test_claimed_compilation_requires_completed_workflow_and_bound_receipts(self):
        project=self.root/'inputs/project';project.mkdir();save(project/'profile.json',{})
        script=self.root/'.agents/skills/mql5-coding/scripts/Invoke-Mql5Project.ps1';script.parent.mkdir(parents=True);script.write_text('# fixture control; never executed')
        save(project/'mql5-compile-a.json',{'status':'success','source':{'path':str(project/'A.mq5')}})
        save(project/'mql5-compile-b.json',{'status':'success','source':{'path':str(project/'B.mq5')}})
        (self.root/'outputs/impact').mkdir();save(self.root/'outputs/impact/result.json',{'possible_affected_entrypoints':['A.mq5','B.mq5']})
        final={**self.final,'case_id':'deleted-header-impact','limitations':['Synthetic only']}
        self.assertIn('No completed successful supplied compilation with receipt evidence',grade('deleted-header-impact',self.root,final,self.events,{}))
        command='& "'+str(script)+'" -ProfilePath inputs/project/profile.json -Action Compile'
        item={'type':'command_execution','command':command,'status':'completed','exit_code':0,'aggregated_output':'MQL5_COMPILE_RECEIPT='+str(project/'mql5-compile-a.json')+'\n'}
        for changes in ({'exit_code':2},{'exit_code':False},{'status':'in_progress'},{'aggregated_output':''},{'command':'Get-Content inputs/project/profile.json'}):
            with self.subTest(changes=changes):
                events=[{'type':'item.completed','item':{**item,**changes}}]
                self.assertIn('No completed successful supplied compilation with receipt evidence',compiled_outcome(self.root,events,None))
        self.assertIn('Trusted compilation receipt verification unavailable',compiled_outcome(self.root,[{'type':'item.completed','item':item}],None))
    def test_compile_observation_rejects_inert_mentions_and_foreign_scripts(self):
        project=self.root/'inputs/project';project.mkdir();save(project/'profile.json',{})
        script=self.root/'.agents/skills/mql5-coding/scripts/Invoke-Mql5Project.ps1';script.parent.mkdir(parents=True);script.write_text('# fixture control; never executed')
        direct='& "'+str(script)+'" -ProfilePath inputs/project/profile.json -Action Compile'
        host=self.root/'pwsh.exe';host.write_bytes(b'identity fixture; never executed')
        file_call='"'+str(host)+'" -NoProfile -File "'+str(script)+'" -ProfilePath inputs/project/profile.json -Action Compile'
        command_call='"'+str(host)+'" -NoProfile -Command \''+direct+'\''
        for command in (direct,direct+'; exit $LASTEXITCODE',direct.replace('-ProfilePath inputs/project/profile.json',"-ProfilePath:'inputs/project/profile.json'")):
            with self.subTest(command=command):self.assertTrue(supplied_compile_command(self.root,command))
        for command in (file_call,command_call):
            with self.subTest(command=command):
                self.assertTrue(supplied_compile_command(self.root,command,powershell_host=host))
                self.assertFalse(supplied_compile_command(self.root,command))
                foreign=self.root/'foreign/pwsh.exe';foreign.parent.mkdir(exist_ok=True);foreign.write_bytes(b'inert foreign fixture')
                self.assertFalse(supplied_compile_command(self.root,command.replace(str(host),str(foreign)),powershell_host=host))
        for command in ('# '+direct,'Write-Output \''+direct+'\'','$text=\''+direct+'\'',
                        direct.replace(str(script),'C:/native/Invoke-Mql5Project.ps1'),
                        'Get-Content "'+str(script)+'" -ProfilePath inputs/project/profile.json -Action Compile',
                        direct+'; Write-Output done',direct+' | Out-Null',direct.replace('-Action Compile','-Action $selection')):
            with self.subTest(command=command):self.assertFalse(supplied_compile_command(self.root,command))
    def test_source_review_requires_location_and_documentation(self):
        final={**self.final,'case_id':'standalone-source-review'}
        save(self.root/'outputs/review.json',{'issues':[{'code':'ARRAY_OUT_OF_BOUNDS','line':5,'trigger':'Loop reaches 3','consequence':'Index exceeds 0..2'}]})
        documented=[{'item':{'type':'command_execution','command':'Get-Content inputs/Review.mq5'}},self.documented()]
        self.assertEqual(grade('standalone-source-review',self.root,final,documented,{}),[])
        self.assertTrue(grade('standalone-source-review',self.root,final,[],{}))
        save(self.root/'outputs/review.json',{'issues':[None]})
        self.assertTrue(grade('standalone-source-review',self.root,final,documented,{}))
    def test_report_expectations_and_hash_linkage_are_independent(self):
        final={**self.final,'case_id':'report-comparison'};(self.root/'outputs/comparison').mkdir()
        result={'compatibility':{'status':'incompatible'},'metrics':{'net_profit':{'difference':{'value':'110.19'}}},'expectations':{'status':'not_requested'},'baseline':{'evidence_linkage':{'status':'hash_verified'}},'candidate':{'evidence_linkage':{'status':'hash_verified'}}}
        save(self.root/'outputs/comparison/result.json',result)
        self.assertEqual(grade('report-comparison',self.root,final,self.events,{}),[])
        result['expectations']['status']='pass';save(self.root/'outputs/comparison/result.json',result)
        self.assertTrue(grade('report-comparison',self.root,final,[],{}))
    def test_source_review_findings_container_preserves_requirements(self):
        final={**self.final,'case_id':'standalone-source-review'}
        documented=[{'item':{'type':'command_execution','command':'Get-Content inputs/Review.mq5'}},self.documented()]
        finding={'code':'ARRAY_OUT_OF_BOUNDS','line':5,'trigger':'Fourth loop iteration accesses samples[3]','consequence':'Array bounds error stops the program'}
        save(self.root/'outputs/review.json',{'findings':[finding]})
        self.assertEqual(grade('standalone-source-review',self.root,final,documented,{}),[])
        for field,value in (('line',4),('trigger',''),('consequence','')):
            save(self.root/'outputs/review.json',{'findings':[{**finding,field:value}]})
            self.assertIn('Concrete source defect was not located/explained',grade('standalone-source-review',self.root,final,documented,{}))
        save(self.root/'outputs/review.json',{'findings':[None]})
        self.assertTrue(grade('standalone-source-review',self.root,final,documented,{}))
    def test_independent_boundary_expression(self):
        cases=[{'n':n,'maximum':3,'expected':min(max(n,0),3)} for n in (-2,0,2,3,4)]
        self.assertTrue(evaluate_calculation('int ClampCount(int n,int maximum){return MathMin(MathMax(n,0),maximum);}',cases))
        self.assertFalse(evaluate_calculation('int ClampCount(int n,int maximum){return MathMin(n,maximum);}',cases))
        self.assertFalse(evaluate_calculation('int ClampCount(int n,int maximum){return __import__("os");}',cases))
    def test_authorized_calculation_fix_keeps_specification_immutable(self):
        cases=[{'n':n,'maximum':3,'expected':max(0,min(n,3))} for n in (-2,0,2,3,4)]+[{'n':2,'maximum':0,'expected':0}]
        original='int ClampCount(int n,int maximum){return MathMin(n,maximum);}'
        revised='int ClampCount(int n,int maximum){return MathMin(MathMax(n,0),maximum);}'
        inputs=self.root/'inputs';outputs=self.root/'outputs'
        save(inputs/'specification.json',{'cases':cases});(inputs/'Calculation.mqh').write_text(original)
        before=inventory(inputs);save(outputs/'cases.json',cases)
        (inputs/'Calculation.mqh').write_text(revised);(outputs/'Calculation.mqh').write_text(revised)
        (outputs/'SelfTest.mq5').write_text(assertion_source(cases))
        final={**self.final,'case_id':'isolated-behavior-tests','limitations':['Prepared only; native MQL5 execution unavailable']}
        self.assertEqual(grade('isolated-behavior-tests',self.root,final,self.events,before),[])
        (inputs/'Calculation.mqh').write_text('unrelated destruction')
        self.assertIn('Revised calculation source differs from the required output',grade('isolated-behavior-tests',self.root,final,self.events,before))
        (inputs/'Calculation.mqh').write_text(revised);save(inputs/'specification.json',{'cases':cases,'changed':True})
        self.assertIn('Input evidence changed: specification.json',grade('isolated-behavior-tests',self.root,final,self.events,before))

def assertion_source(cases):
    return '#include "Calculation.mqh"\nvoid OnStart()\n{\n'+'\n'.join('if(ClampCount('+str(c['n'])+','+str(c['maximum'])+')!='+str(c['expected'])+') Print("FAIL:case '+str(i)+'");' for i,c in enumerate(cases))+'\n}\n'

class CalculationLiterals(unittest.TestCase):
    def setUp(self):
        self.cases=[{'n':n,'maximum':3,'expected':max(0,min(n,3))} for n in (-2,0,2,3,4)]+[{'n':2,'maximum':0,'expected':0}]
    def source(self,literal):
        return 'int ClampCount(int n,int maximum){return MathMin(MathMax(n,'+literal+'),maximum);}'
    def test_python_only_spellings_cannot_pass_mql5_preparation(self):
        # MetaEditor 6252 rejects these spelling families; native compilation
        # evidence is retained separately from this dependency-free grader test.
        for literal in ('0_0','0_00','0o0','0o_0','0b0','0b_0','0x_0','0x0_0'):
            with self.subTest(literal=literal):self.assertFalse(evaluate_calculation(self.source(literal),self.cases))
    def test_decimal_and_hexadecimal_control_spellings_remain_supported(self):
        for literal in ('0','00','000','0x0','0X0','-0'):
            with self.subTest(literal=literal):self.assertTrue(evaluate_calculation(self.source(literal),self.cases))
        self.assertTrue(evaluate_calculation('int ClampCount(int n,int maximum){return MathMin(MathMax(n,0),MathMin(maximum,0Xa));}',self.cases))
    def test_supported_literals_do_not_bypass_independent_expected_values(self):
        self.assertFalse(evaluate_calculation(self.source('0x1'),self.cases))
        self.assertFalse(evaluate_calculation(self.source('1'),self.cases))
    def test_completed_preparation_artifacts_cannot_hide_python_literals(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);inputs=root/'inputs';outputs=root/'outputs';inputs.mkdir();outputs.mkdir()
            save(inputs/'specification.json',{'cases':self.cases});save(outputs/'cases.json',self.cases)
            (outputs/'SelfTest.mq5').write_text(assertion_source(self.cases))
            final={'case_id':'isolated-behavior-tests','status':'limited','findings':[],'evidence':[],'limitations':['No native execution']}
            for literal in ('0_0','0o0','0b0'):
                code=self.source(literal);(inputs/'Calculation.mqh').write_text(code);(outputs/'Calculation.mqh').write_text(code)
                with self.subTest(literal=literal):
                    self.assertIn('Calculation expression fails the independent boundary specification',grade('isolated-behavior-tests',root,final,[],inventory(inputs)))
    def test_comments_are_processed_before_literal_spelling_checks(self):
        source='int ClampCount(int n,int maximum){return MathMin(MathMax(n,/* Python 0_0 is irrelevant here */0),maximum);}'
        self.assertTrue(evaluate_calculation(source,self.cases))
    def test_python_selection_keeps_its_own_valid_integer_syntax(self):
        from evaluate_workflows import evaluate_python_calculation
        for literal in ('0_0','0o0','0b0','0x_0'):
            with self.subTest(literal=literal):
                code='def clamp_count(n,maximum):\n    return min(max(n,'+literal+'),maximum)\n'
                self.assertTrue(evaluate_python_calculation(code,self.cases))

class Assertions(unittest.TestCase):
    def setUp(self):
        self.cases=[{'n':n,'maximum':3,'expected':max(0,min(n,3))} for n in (-2,0,2,3,4)]+[{'n':2,'maximum':0,'expected':0}]
        self.code=assertion_source(self.cases)
    def test_active_assertions_check_each_independent_expected_value(self):
        self.assertTrue(evaluate_assertions(self.code,self.cases))
        self.assertTrue(evaluate_assertions('#property strict\n// preparation only\n'+self.code,self.cases))
        self.assertTrue(evaluate_assertions(assertion_source(list(reversed(self.cases))),self.cases))
    def test_comments_and_strings_cannot_stand_in_for_active_checks(self):
        for code in ('\n'.join('// ClampCount('+str(c['n'])+','+str(c['maximum'])+')' for c in self.cases),
                     '/*'+self.code+'*/',
                     '#include "Calculation.mqh"\nvoid OnStart(){Print("ClampCount(-2,3)");}',
                     self.code.replace('if(ClampCount(-2,3)!=0)','// if(ClampCount(-2,3)!=0)')):
            with self.subTest(code=code):self.assertFalse(evaluate_assertions(code,self.cases))
    def test_incorrect_expected_values_and_missing_cases_fail(self):
        wrong=[{**c,'expected':999} for c in self.cases]
        for code in (assertion_source(wrong),assertion_source(self.cases[:-1]),assertion_source(self.cases[:-1]+[self.cases[0]])):
            with self.subTest(code=code):self.assertFalse(evaluate_assertions(code,self.cases))
    def test_assertion_integers_use_native_ascii_decimal_digits(self):
        self.assertTrue(evaluate_assertions('// Unicode comment: \uff4e\n'+self.code.replace('FAIL:case','FAIL:\u0662\uff10 case'),self.cases))
        for digits in ('\u0660\u0661\u0662\u0663\u0664\u0665\u0666\u0667\u0668\u0669','\uff10\uff11\uff12\uff13\uff14\uff15\uff16\uff17\uff18\uff19'):
            with self.subTest(digits=digits):self.assertFalse(evaluate_assertions(self.code.translate(str.maketrans('0123456789',digits)),self.cases))
    def test_disconnected_or_conditionally_disabled_assertions_fail(self):
        for code in (self.code.replace('OnStart','Unused'),self.code.replace('{\n','{\nreturn;\n',1),
                     '#if 0\n'+self.code+'#endif',self.code.replace('if(ClampCount(-2,3)!=0)','if(false) if(ClampCount(-2,3)!=0)'),
                     self.code.replace('Print("FAIL:case 0");','OrderSend(request,result);'),
                     self.code+'void OnTick(){OrderSend(request,result);}'):
            with self.subTest(code=code):self.assertFalse(evaluate_assertions(code,self.cases))
    def test_broken_comments_or_strings_fail(self):
        self.assertFalse(evaluate_assertions(self.code+'/*',self.cases))
        self.assertFalse(evaluate_assertions(self.code.replace('FAIL:case 0"','FAIL:case 0'),self.cases))
    def test_physical_line_endings_preserve_active_comment_controls(self):
        calculation='// contract\nint ClampCount(int n,int maximum){return MathMin(MathMax(n,0),maximum);}'
        source='// preparation only\n'+self.code
        for newline in ('\n','\r\n','\r'):
            with self.subTest(newline=repr(newline)):
                self.assertTrue(evaluate_calculation(calculation.replace('\n',newline),self.cases))
                self.assertTrue(evaluate_assertions(source.replace('\n',newline),self.cases))
                multiline=source.replace('FAIL:case 0','FAIL:\ncase 0').replace('\n',newline)
                self.assertFalse(evaluate_assertions(multiline,self.cases))
    def test_comment_only_or_string_calculation_does_not_pass(self):
        correct='int ClampCount(int n,int maximum){return MathMin(MathMax(n,0),maximum);}'
        self.assertTrue(evaluate_calculation('// contract\n'+correct,self.cases))
        for code in ('// '+correct,'/*'+correct+'*/','"'+correct+'"',correct+' void OnTick(){}','#if 0\n'+correct+'\n#endif'):
            with self.subTest(code=code):self.assertFalse(evaluate_calculation(code,self.cases))
    def test_expression_layout_preserves_original_mql5_comment_controls(self):
        for separator in (' ','\n','\t','/* comment\n*/','// comment\n'):
            code='int ClampCount(int n,int maximum){return MathMin'+separator+'(MathMax(n,0),maximum);}'
            with self.subTest(separator=separator):self.assertTrue(evaluate_calculation(code,self.cases))
        for code in ('int ClampCount(int n,int maximum){return Math Min(MathMax(n,0),maximum);}',
                     'int ClampCount(int n,int maximum){return MathMin(/*broken (MathMax(n,0),maximum);}',
                     'int ClampCount(int n,int maximum){return MathMin(MathMax(n,0),maximum); } void OnTick() {}'):
            with self.subTest(code=code):self.assertFalse(evaluate_calculation(code,self.cases))
    def test_expression_identifiers_preserve_mql5_ascii_identity(self):
        correct='int ClampCount(int n,int maximum){return MathMin(MathMax(n,0),maximum);}'
        self.assertTrue(evaluate_calculation(correct,self.cases))
        self.assertTrue(evaluate_calculation(correct.replace('MathMin','/* Unicode comment: \uff4e \U0001d4c3 */ MathMin'),self.cases))
        for replacement in ('\uff4e','\U0001d4c3'):
            with self.subTest(identifier=replacement):self.assertFalse(evaluate_calculation(correct.replace('MathMax(n,','MathMax('+replacement+','),self.cases))
    def test_grade_requires_active_checks_and_integer_case_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'inputs').mkdir();(root/'outputs').mkdir()
            final={'case_id':'isolated-behavior-tests','status':'limited','findings':[],'evidence':[],'limitations':['No native execution']}
            events=[{'type':'item.completed','item':{'type':'command_execution','command':'Get-Content inputs/specification.json'}}]
            save(root/'inputs/specification.json',{'cases':self.cases});save(root/'outputs/cases.json',self.cases)
            (root/'outputs/Calculation.mqh').write_text('int ClampCount(int n,int maximum){return MathMin(MathMax(n,0),maximum);}')
            (root/'outputs/SelfTest.mq5').write_text(self.code)
            self.assertEqual(grade('isolated-behavior-tests',root,final,events,{}),[])
            (root/'outputs/SelfTest.mq5').write_text('/*'+self.code+'*/')
            self.assertIn('Missing active assertion or incorrect independently specified expected value',grade('isolated-behavior-tests',root,final,events,{}))
            (root/'outputs/SelfTest.mq5').write_text(self.code)
            equivalent=[{**c,'expected':False if c['expected']==0 else c['expected']} for c in self.cases]
            save(root/'outputs/cases.json',equivalent)
            self.assertIn('Test cases differ from independent specification',grade('isolated-behavior-tests',root,final,events,{}))

@unittest.skipUnless(os.name=='nt','Windows synthetic compilation and receipt locks')
class WorkflowReceipts(unittest.TestCase):
    def test_actual_synthetic_project_receipts_and_corrupted_evidence(self):
        host=Path(os.environ.get('ProgramFiles',r'C:\Program Files'))/'PowerShell/7/pwsh.exe'
        legacy=Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
        csc=Path(os.environ['WINDIR'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        if not all(p.is_file() for p in (host,legacy,csc)):self.skipTest('Both supported PowerShell hosts and synthetic compiler preparation are required')
        safe_env={k:v for k,v in os.environ.items() if not k.startswith('FAKE_METAEDITOR_')}
        with tempfile.TemporaryDirectory(prefix='mql5-eval-proof-') as temp, patch.dict(os.environ,safe_env,clear=True):
            root=Path(temp);binaries=root/'binaries';binaries.mkdir()
            subprocess.run([str(csc),'/nologo','/target:exe','/out:'+str(binaries/'metaeditor64.exe'),str(REPO/'tests/FakeMetaEditor.cs')],capture_output=True,check=True)
            shutil.copy2(binaries/'metaeditor64.exe',binaries/'terminal64.exe')
            work=root/'workspace';work.mkdir();staged=work/'.agents/skills/mql5-coding';shutil.copytree(REPO/'skills/mql5-coding',staged)
            context=prepare('deleted-header-impact',work,staged,host,Path(sys.executable),binaries)
            staged_before=inventory(staged)
            (work/'outputs/impact').mkdir();save(work/'outputs/impact/result.json',{'possible_affected_entrypoints':['A.mq5','B.mq5']})
            script=staged/'scripts/Invoke-Mql5Project.ps1';profile=work/'inputs/project/profile.json'
            response=ps(host,script,{'ProfilePath':profile,'Action':'Compile','SuppressLogOutput':True},work)
            self.assertEqual(response.returncode,0,response.stderr.decode(errors='replace'))
            output=response.stdout.decode('utf-8-sig');command='& "'+str(script)+'" -ProfilePath "'+str(profile)+'" -Action Compile -SuppressLogOutput'
            events=[{'type':'item.completed','item':{'type':'command_execution','command':command,'aggregated_output':output,'exit_code':0,'status':'completed'}}]
            final={'case_id':'deleted-header-impact','status':'completed','findings':[],'evidence':['outputs/impact/result.json'],'limitations':['Synthetic execution establishes no native MQL5 behavior']}
            for powershell in (host,legacy):
                with self.subTest(host=powershell.name):
                    verifier=lambda paths:verify_workflow_receipts(powershell,REPO/'skills/mql5-coding',work,paths)
                    self.assertEqual(grade('deleted-header-impact',work,final,events,context['input_hashes'],receipt_verifier=verifier,staged_before=staged_before),[])
            verifier=lambda paths:verify_workflow_receipts(host,REPO/'skills/mql5-coding',work,paths)
            host_command='"'+str(host)+'" -NoProfile -File "'+str(script)+'" -ProfilePath "'+str(profile)+'" -Action Compile'
            hosted=[{'type':'item.completed','item':{**events[0]['item'],'command':host_command}}]
            self.assertEqual(grade('deleted-header-impact',work,final,hosted,context['input_hashes'],receipt_verifier=verifier,staged_before=staged_before,powershell_host=host),[])
            self.assertIn('No completed successful supplied compilation with receipt evidence',grade('deleted-header-impact',work,final,hosted,context['input_hashes'],receipt_verifier=verifier,staged_before=staged_before,powershell_host=legacy))
            receipt_paths=[Path(line.split('=',1)[1]) for line in output.splitlines() if line.startswith('MQL5_COMPILE_RECEIPT=')]
            self.assertEqual(len(receipt_paths),2)
            original_script=script.read_bytes()
            try:
                markers=[line for line in output.replace('\r\n','\n').split('\n') if line.startswith('MQL5_COMPILE_RECEIPT=')]
                script.write_text('param([string]$ProfilePath,[string]$Action)\n'+''.join("Write-Output '"+line.replace("'","''")+"'\n" for line in markers)+'exit 0\n')
                inert=ps(host,script,{'ProfilePath':profile,'Action':'Compile'},work)
                self.assertEqual(inert.returncode,0)
                replacement=[{'type':'item.completed','item':{'type':'command_execution','command':command.removesuffix(' -SuppressLogOutput'),'aggregated_output':inert.stdout.decode('utf-8-sig'),'exit_code':0,'status':'completed'}}]
                self.assertIn('Selected staged skill changed: scripts/Invoke-Mql5Project.ps1',grade('deleted-header-impact',work,final,replacement,context['input_hashes'],receipt_verifier=verifier,staged_before=staged_before))
            finally:script.write_bytes(original_script)
            receipt=next(p for p in receipt_paths if json.loads(p.read_text(encoding='utf-8-sig'))['source']['path'].endswith('A.mq5'))
            original=receipt.read_bytes();value=json.loads(original.decode('utf-8-sig'))
            source=work/'inputs/project/A.mq5';expert=work/'inputs/project/A.ex5';log=Path(value['log']['path'])
            for name,path,replacement in (('fabricated',receipt,json.dumps({'status':'success','source':{'path':str(source)}}).encode()),
                                          ('missing artifact',expert,None),('stale source',source,b'changed source'),
                                          ('stale artifact',expert,b'changed artifact'),('missing log',log,None)):
                previous=path.read_bytes()
                try:
                    if replacement is None:path.unlink()
                    else:path.write_bytes(replacement)
                    with self.subTest(case=name):self.assertIn('Affected entrypoint receipt/artifact/log evidence failed verification',compiled_outcome(work,events,verifier))
                finally:path.write_bytes(previous)
            try:
                value['source']['path']=str(work/'inputs/project/B.mq5');save(receipt,value)
                self.assertIn('Affected entrypoint receipt/artifact/log evidence failed verification',compiled_outcome(work,events,verifier))
            finally:receipt.write_bytes(original)

@unittest.skipUnless(os.name=='nt','Windows job object execution')
class Process(unittest.TestCase):
    def test_cleanup_waits_for_inherited_output_handles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);releases=[];original_open=Path.open
            @contextmanager
            def delayed_output_close(path,*args,**kwargs):
                with original_open(path,*args,**kwargs) as stream:
                    retained=os.dup(stream.fileno()) if path==root/'stderr' and args==('xb',) else None
                    try:yield stream
                    finally:
                        if retained is not None:
                            release=threading.Thread(target=lambda: (time.sleep(.3),os.close(retained)))
                            releases.append(release);release.start()
            try:
                with patch.object(Path,'open',delayed_output_close):
                    measurement=run_owned([sys.executable,'-I','-B','-c','pass'],root,root/'trace',root/'stderr',seconds=5)
                self.assertTrue(measurement['cleanup_verified'])
                # Kernel cleanup may release inherited files after job accounting
                # reaches zero. Verified cleanup must make evidence movable now.
                (root/'stderr').rename(root/'released-stderr')
            finally:
                for release in releases:release.join(timeout=5)

    def test_cleanup_remains_unverified_if_output_handle_cannot_be_released(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);retained=[];original_open=Path.open
            @contextmanager
            def retained_output(path,*args,**kwargs):
                with original_open(path,*args,**kwargs) as stream:
                    if path==root/'stderr' and args==('xb',):retained.append(os.dup(stream.fileno()))
                    yield stream
            try:
                with patch.object(Path,'open',retained_output):
                    measurement=run_owned([sys.executable,'-I','-B','-c','pass'],root,root/'trace',root/'stderr',seconds=5)
                self.assertFalse(measurement['cleanup_verified'])
                self.assertEqual(measurement['status'],'completed')
                self.assertEqual(measurement['exit_code'],0)
                # Failed two-file probes must release their first acquired handle.
                (root/'trace').rename(root/'released-trace')
            finally:
                for handle in retained:os.close(handle)

    def test_completed_output_burst_cannot_bypass_limit(self):
        for stream in ('stdout','stderr'):
            with self.subTest(stream=stream), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                code='import sys;sys.'+stream+'.buffer.write(b"x"*17825792)'
                measurement=run_owned([sys.executable,'-I','-B','-c',code],root,root/'trace',root/'stderr',seconds=5)
                self.assertEqual(measurement['status'],'output_limit')
                self.assertIsNone(measurement['exit_code'])
                self.assertTrue(measurement['cleanup_verified'])
                self.assertGreater(measurement['console_bytes'],16777216)
    def test_exact_output_limit_remains_completed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            measurement=run_owned([sys.executable,'-I','-B','-c','import sys;sys.stdout.buffer.write(b"x"*16777216)'],root,root/'trace',root/'stderr',seconds=5)
            self.assertEqual(measurement['status'],'completed')
            self.assertEqual(measurement['exit_code'],0)
            self.assertTrue(measurement['cleanup_verified'])
            self.assertEqual(measurement['console_bytes'],16777216)
    def test_synthetic_codex_trace_and_final(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);script=root/'fake_codex.py';script.write_text('import json\nprint(json.dumps({"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":1}}))\n')
            measurement=run_owned([sys.executable,str(script)],root,root/'trace',root/'stderr',seconds=5)
            self.assertEqual(measurement['status'],'completed');self.assertEqual(measurement['exit_code'],0);self.assertTrue(measurement['cleanup_verified'])
            self.assertEqual(read_trace(root/'trace')[0][0]['usage']['input_tokens'],2)
    def test_timeout_kills_owned_descendant(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);pid=root/'child';script=root/'fake_codex.py'
            script.write_text('import subprocess,sys,time\nfrom pathlib import Path\np=subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"])\nPath(sys.argv[1]).write_text(str(p.pid))\ntime.sleep(30)\n')
            measurement=run_owned([sys.executable,str(script),str(pid)],root,root/'trace',root/'stderr',seconds=1)
            self.assertEqual(measurement['status'],'timed_out');self.assertTrue(measurement['cleanup_verified']);self.assertIsNone(measurement['exit_code'])
    def test_failed_process_keeps_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);measurement=run_owned([sys.executable,'-c','import sys;print("malformed");sys.exit(2)'],root,root/'trace',root/'stderr',seconds=5)
            self.assertEqual(measurement['exit_code'],2);self.assertTrue(measurement['cleanup_verified']);self.assertTrue(read_trace(root/'trace')[1])
if __name__=='__main__':unittest.main()
