"""Independent scorer and bounded process tests; no model credentials required."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from evaluate_workflows import SCHEMA, evaluate_calculation, grade, inventory, read_trace, save
from workflow_process import run_owned

class Scoring(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        (self.root/'inputs').mkdir();(self.root/'outputs').mkdir()
        self.final={'case_id':'scenario-validation','status':'completed','findings':[{'code':'validated','detail':'Whole configuration checked'}],'evidence':['outputs/validation/result.json'],'limitations':[]}
        self.events=[{'type':'item.completed','item':{'type':'command_execution','command':'Invoke-Mql5ScenarioBatch.ps1 -Action Validate'}}]
        (self.root/'outputs/validation').mkdir();save(self.root/'outputs/validation/result.json',{'status':'validated','action':'Validate'})
    def tearDown(self):self.temp.cleanup()
    def test_correct_artifact(self):self.assertEqual(grade('scenario-validation',self.root,self.final,self.events,{}),[])
    def test_claim_does_not_replace_evidence(self):
        (self.root/'outputs/validation/result.json').unlink();self.assertTrue(grade('scenario-validation',self.root,self.final,self.events,{}))
    def test_wrong_conclusion(self):
        self.final['status']='failed';self.assertTrue(grade('scenario-validation',self.root,self.final,self.events,{}))
    def test_forbidden_launch(self):
        self.events.append({'item':{'type':'command_execution','command':r'& C:\fake\terminal64.exe /config:run.ini'}})
        self.assertIn('Forbidden terminal launch',grade('scenario-validation',self.root,self.final,self.events,{}))
    def test_missing_metrics_do_not_invent_evidence(self):self.assertEqual(grade('scenario-validation',self.root,self.final,self.events,{}),[])
    def test_schema_types(self):
        self.final['findings']=[{'code':3,'detail':'bad'}];self.assertTrue(grade('scenario-validation',self.root,self.final,self.events,{}))
    def test_input_mutation(self):self.assertTrue(grade('scenario-validation',self.root,self.final,self.events,{'x':'0'*64}))
    def test_malformed_trace(self):
        p=self.root/'trace';p.write_text('{}\n[]\ninvalid\n');events,issues=read_trace(p);self.assertEqual(len(events),1);self.assertEqual(len(issues),2)
    def test_malformed_item_is_failed_evidence(self):
        self.assertTrue(grade('scenario-validation',self.root,self.final,[{'item':'invalid'}],{}))
    def test_every_case_requires_its_independent_artifact(self):
        for case in ('report-comparison','deleted-header-impact','journal-grouping','standalone-source-review','profile-without-conditions','isolated-behavior-tests'):
            final={**self.final,'case_id':case,'limitations':['Not executed natively']}
            self.assertTrue(grade(case,self.root,final,[],{}),case)
    def test_source_review_requires_location_and_documentation(self):
        final={**self.final,'case_id':'standalone-source-review'}
        save(self.root/'outputs/review.json',{'issues':[{'line':5,'trigger':'Loop reaches 3','consequence':'Index exceeds 0..2'}]})
        documented=[{'item':{'type':'command_execution','command':'Get-Content inputs/Review.mq5'}},{'item':{'type':'mcp_tool_call','server':'mql5-chm','tool':'mql5_chm_read','status':'completed'}}]
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
        documented=[{'item':{'type':'command_execution','command':'Get-Content inputs/Review.mq5'}},{'item':{'type':'mcp_tool_call','server':'mql5-chm','tool':'mql5_chm_read','status':'completed'}}]
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
        (outputs/'SelfTest.mq5').write_text('\n'.join('Check(ClampCount('+str(c['n'])+','+str(c['maximum'])+')=='+str(c['expected'])+');' for c in cases))
        final={**self.final,'case_id':'isolated-behavior-tests','limitations':['Prepared only; native MQL5 execution unavailable']}
        self.assertEqual(grade('isolated-behavior-tests',self.root,final,self.events,before),[])
        (inputs/'Calculation.mqh').write_text('unrelated destruction')
        self.assertIn('Revised calculation source differs from the required output',grade('isolated-behavior-tests',self.root,final,self.events,before))
        (inputs/'Calculation.mqh').write_text(revised);save(inputs/'specification.json',{'cases':cases,'changed':True})
        self.assertIn('Input evidence changed: specification.json',grade('isolated-behavior-tests',self.root,final,self.events,before))

@unittest.skipUnless(os.name=='nt','Windows job object execution')
class Process(unittest.TestCase):
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
