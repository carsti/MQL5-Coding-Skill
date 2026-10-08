"""Selection grading controls, independently constructed artifacts and traces."""
import json
from pathlib import Path
import tempfile
import unittest
from evaluate_workflows import CASES, SELECTION_CASES, REPO, SCHEMA, grade, inventory, prepare, save, selection_resources, workflow_prompt, evaluate_python_calculation, relevant_array_documentation

class Selection(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
  self.skill=self.root/'.agents/skills/mql5-coding';self.skill.mkdir(parents=True)
  (self.skill/'SKILL.md').write_text('This is the selected maintained coding resource.\nUse relevant platform evidence for specific API conclusions.\n')
 def tearDown(self):self.temp.cleanup()
 def context(self,case):return prepare(case,self.root,self.skill,Path('C:/host/pwsh.exe'),Path('C:/python.exe'),Path('C:/unused'))
 def final(self,case):return {'case_id':case,'status':'completed','findings':[],'evidence':[],'limitations':[]}
 def event(self,command,output='processed evidence'):
  return {'type':'item.completed','item':{'type':'command_execution','status':'completed','exit_code':0,'command':command,'aggregated_output':output}}
 def test_default_seven_and_four_optional(self):self.assertEqual(len(CASES),7);self.assertEqual(len(SELECTION_CASES),4)
 def test_selection_prompts_omit_skill_names_and_paths(self):
  for case in SELECTION_CASES:
   with self.subTest(case=case):
    text=workflow_prompt(case,{'task':'Perform the supplied task.'},self.skill,Path('C:/python.exe'),Path('C:/pwsh.exe'))
    self.assertNotIn('mql5-coding',text);self.assertNotIn('SKILL.md',text);self.assertNotIn(str(self.skill),text)
    if case in ('selection-mql4-inventory','selection-python-repair'):self.assertNotIn('MetaEditor',text);self.assertNotIn('MT5',text)
 def test_original_prompt_remains_explicit(self):self.assertIn(str(self.skill/'SKILL.md'),workflow_prompt(CASES[0],{'task':'Compare reports'},self.skill,Path('C:/python.exe'),Path('C:/pwsh.exe')))
 def test_completed_resource_bytes_are_evidence(self):
  events=[self.event('Get-Content '+str(self.skill/'SKILL.md'),(self.skill/'SKILL.md').read_text())]
  self.assertEqual(selection_resources(self.root,events),['SKILL.md'])
 def test_usage_claim_or_empty_failed_read_is_not_evidence(self):
  for events in ([self.event('Write-Output "I used '+str(self.skill/'SKILL.md')+'"')],[self.event('Get-Content '+str(self.skill/'SKILL.md'),'I used the skill')]):self.assertEqual(selection_resources(self.root,events),[])
  event=self.event('Get-Content '+str(self.skill/'SKILL.md'),(self.skill/'SKILL.md').read_text());event['item']['exit_code']=1
  self.assertEqual(selection_resources(self.root,[event]),[])
 def test_inert_reader_mentions_cannot_borrow_resource_output(self):
  text=(self.skill/'SKILL.md').read_text()
  for command in ("Write-Output 'Get-Content "+str(self.skill/'SKILL.md')+"'", "Write-Output 'claimed; Get-Content "+str(self.skill/'SKILL.md')+"'"):
   self.assertEqual(selection_resources(self.root,[self.event(command,text)]),[])
 def test_rg_and_literal_host_reads_are_observed(self):
  for command in ('rg -n . '+str(self.skill/'SKILL.md'), 'powershell.exe -NoProfile -Command "Get-Content '+str(self.skill/'SKILL.md')+'"'):
   self.assertEqual(selection_resources(self.root,[self.event(command,(self.skill/'SKILL.md').read_text())]),['SKILL.md'])
 def test_completed_selected_helper_is_observed_resource_use(self):
  scripts=self.skill/'scripts';scripts.mkdir();tool=scripts/'mql5_toolkit.py';tool.write_text('# selected helper')
  event=self.event('python -B "'+str(tool)+'" report compare --baseline baseline --candidate candidate --output output','report compare\nStatus: completed');event['item']['exit_code']=3
  self.assertEqual(selection_resources(self.root,[event]),['scripts/mql5_toolkit.py'])
  event['item']['command']='Write-Output \'python -B "'+str(tool)+'" report compare\''
  self.assertEqual(selection_resources(self.root,[event]),[])
 def make_inventory(self):
  context=self.context('selection-mql4-inventory');files=[{'path':p.relative_to(self.root/'inputs').as_posix(),'extension':p.suffix,'bytes':p.stat().st_size} for p in sorted((self.root/'inputs').rglob('*')) if p.is_file()]
  save(self.root/'outputs/inventory.json',{'files':files});return context
 def test_general_inventory_passes_without_platform_resources(self):
  c=self.make_inventory();self.assertEqual(grade(c['case'],self.root,self.final(c['case']),[self.event('Get-ChildItem inputs -Recurse')],c['input_hashes']),[])
 def test_inventory_claim_does_not_replace_bytes(self):
  c=self.make_inventory();save(self.root/'outputs/inventory.json',{'files':[]});self.assertIn('Incorrect file inventory',grade(c['case'],self.root,self.final(c['case']),[self.event('Get-ChildItem inputs')],c['input_hashes']))
 def test_general_task_rejects_documentation_calls(self):
  c=self.make_inventory();events=[self.event('Get-ChildItem inputs'),{'type':'item.completed','item':{'type':'mcp_tool_call','server':'mql5-chm','tool':'mql5_chm_search','status':'completed'}}]
  self.assertIn('Unrelated platform resources used for a general task',grade(c['case'],self.root,self.final(c['case']),events,c['input_hashes']))
 def test_general_task_rejects_body_read(self):
  c=self.make_inventory();events=[self.event('Get-Content '+str(self.skill/'SKILL.md'),(self.skill/'SKILL.md').read_text())]
  self.assertIn('Unrelated platform resources used for a general task',grade(c['case'],self.root,self.final(c['case']),events,c['input_hashes']))
 def test_inventory_preserves_files_and_detects_additions(self):
  c=self.make_inventory();(self.root/'inputs/new.txt').write_text('unexpected')
  self.assertIn('Input evidence files added or removed',grade(c['case'],self.root,self.final(c['case']),[self.event('Get-ChildItem inputs')],c['input_hashes']))
 def repair(self):
  c=self.context('selection-python-repair');code='def clamp_count(n, maximum):\n    return max(0, min(n, maximum))\n'
  (self.root/'inputs/calculation.py').write_text(code);(self.root/'outputs/calculation.py').write_text(code)
  save(self.root/'outputs/cases.json',json.loads((self.root/'inputs/specification.json').read_text())['cases']);return c
 def test_python_repair_has_independent_correct_values(self):
  c=self.repair();self.assertEqual(grade(c['case'],self.root,self.final(c['case']),[self.event('Get-Content inputs/calculation.py')],c['input_hashes']),[])
 def test_python_output_must_match_repaired_input(self):
  c=self.repair();(self.root/'inputs/calculation.py').write_text('def clamp_count(n, maximum):\n    return min(n, maximum)\n')
  self.assertTrue(grade(c['case'],self.root,self.final(c['case']),[self.event('Get-Content inputs/calculation.py')],c['input_hashes']))
 def test_python_calculation_does_not_execute_untrusted_code(self):
  cases=[{'n':-2,'maximum':3,'expected':0}]
  for code in ['def clamp_count(n, maximum):\n return min(n, maximum)','import os\ndef clamp_count(n, maximum):\n return 0','def clamp_count(n, maximum):\n return __import__("os").system("bad")','@unknown\ndef clamp_count(n, maximum):\n return 0','def clamp_count(n: dangerous(), maximum):\n return 0']:
   self.assertFalse(evaluate_python_calculation(code,cases))
 def documented(self):
  source='b6b3338a985e1efedc2c87fa478f648d7de53e1daa6d2a8a9e5359b8878e23fa';topic='mql5:02ce7771459932284a2d93ac'
  citation={'source_file':'mql5.chm','topic_id':topic,'source_revision':source,'corpus_revision':'a'*64,'index_revision':'b'*64}
  content={'topic_id':topic,'source_revision':source,'corpus_revision':'a'*64,'index_sha256':'b'*64,'citation':citation,'text':'Arrays: Each dimension is indexed from 0 to dimension_size-1.'}
  return {'type':'item.completed','item':{'type':'mcp_tool_call','server':'mql5-chm','tool':'mql5_chm_read','status':'completed','result':{'structured_content':content}}}
 def test_returned_documentation_is_relevant_and_identified(self):
  event=self.documented();self.assertTrue(relevant_array_documentation([event]))
  for key,value in [('text','Unrelated profitable trading statistic'),('topic_id','mql5:'+'0'*24),('source_revision','f'*64)]:
   altered=json.loads(json.dumps(event));altered['item']['result']['structured_content'][key]=value
   self.assertFalse(relevant_array_documentation([altered]))
 def test_completed_documentation_claim_without_result_fails(self):
  event=self.documented();event['item'].pop('result');self.assertFalse(relevant_array_documentation([event]))
 def test_documentation_error_and_stale_citation_fail(self):
  event=self.documented();event['item']['result']['isError']=True;self.assertFalse(relevant_array_documentation([event]))
  event=self.documented();event['item']['result']['structured_content']['citation']['index_revision']='c'*64
  self.assertFalse(relevant_array_documentation([event]))
 def test_search_can_return_the_verified_relevant_passage(self):
  event=self.documented();content=event['item']['result']['structured_content'];content['snippet']=content.pop('text')
  event['item']['tool']='mql5_chm_search';event['item']['result']['structured_content']={'corpus_revision':'a'*64,'index_sha256':'b'*64,'results':[content]}
  self.assertTrue(relevant_array_documentation([event]))
 def test_positive_review_requires_source_issue_docs_and_resource_read(self):
  c=self.context('selection-mql5-review');save(self.root/'outputs/review.json',{'issues':[{'line':5,'trigger':'i reaches 3','consequence':'Access beyond three elements'}]})
  events=[self.event('Get-Content inputs/Review.mq5'),self.documented()]
  final=self.final(c['case']);self.assertIn('No observed read of selected relevant resources',grade(c['case'],self.root,final,events,c['input_hashes']))
  events.append(self.event('Get-Content '+str(self.skill/'SKILL.md'),(self.skill/'SKILL.md').read_text()))
  self.assertEqual(grade(c['case'],self.root,final,events,c['input_hashes']),[])
if __name__=='__main__':unittest.main()
