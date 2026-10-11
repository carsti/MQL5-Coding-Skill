"""Actual discovery protocol and isolation policy regressions; no service credentials."""
from pathlib import Path
from types import SimpleNamespace
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from evaluate_workflows import resolve_skill_isolation, skill_configuration, skill_listing, unselected_skill_reads
from workflow_skill_discovery import request_skills


class Discovery(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.skill=self.root/'.agents/skills/mql5-coding';self.skill.mkdir(parents=True)
        self.selected={'name':'mql5-coding','path':str(self.skill/'SKILL.md'),'scope':'repo','enabled':True}
        self.user={'name':'unrelated','path':str(self.root/'user/.agents/skills/unrelated/SKILL.md'),'scope':'user','enabled':True}
        self.system={'name':'bundled','path':str(self.root/'private/skills/.system/bundled/SKILL.md'),'scope':'system','enabled':True}
        self.args=SimpleNamespace(codex_path=Path('C:/codex.exe'),python=Path(sys.executable))
    def tearDown(self):self.temp.cleanup()
    def listing(self,skills=None):return {'data':[{'cwd':str(self.root),'errors':[],'skills':skills or [self.selected,self.user,self.system]}]}
    def test_user_and_private_bundled_scopes_disabled_by_file(self):
        commands=[]
        def run(command,cwd,stdout,stderr,**kwargs):
            commands.append(command)
            skills=[dict(s) for s in (self.selected,self.user,self.system)]
            if len(commands)==2:
                for s in skills[1:]:s['enabled']=False
            stdout.write_text(json.dumps(self.listing(skills)));stderr.write_text('')
            return {'status':'completed','exit_code':0,'cleanup_verified':True,'console_bytes':100}
        with patch('evaluate_workflows.run_owned',side_effect=run):
            disabled,proof=resolve_skill_isolation(self.args,self.root,self.skill,self.root/'discovery',{})
        self.assertEqual(proof['status'],'passed');self.assertEqual(len(disabled),2)
        config=next(c for c in commands[1] if c.startswith('skills.config='))
        for s in (self.selected,self.user,self.system):self.assertIn(json.dumps(s['path']),config)
        self.assertTrue(all(Path(s['path']).name=='SKILL.md' and not s['enabled'] for s in disabled))
        self.assertEqual(len(proof['enabled']),1)
    def test_unrelated_enabled_skill_blocks_before_agent_launch(self):
        def run(command,cwd,stdout,stderr,**kwargs):
            stdout.write_text(json.dumps(self.listing()));stderr.write_text('')
            return {'status':'completed','exit_code':0,'cleanup_verified':True,'console_bytes':100}
        with patch('evaluate_workflows.run_owned',side_effect=run):
            _,proof=resolve_skill_isolation(self.args,self.root,self.skill,self.root/'discovery',{})
        self.assertEqual(proof['status'],'failed')
    def test_cleanup_uncertainty_and_invalid_output_preserved(self):
        for index,(clean,text) in enumerate(((False,json.dumps(self.listing())),(True,'[]'),(True,'broken'))):
            def run(command,cwd,stdout,stderr,**kwargs):
                stdout.write_text(text);stderr.write_text('retained')
                return {'status':'completed','exit_code':0,'cleanup_verified':clean,'console_bytes':100}
            target=self.root/('discovery'+str(index))
            with patch('evaluate_workflows.run_owned',side_effect=run):
                _,proof=resolve_skill_isolation(self.args,self.root,self.skill,target,{})
            self.assertEqual(proof['status'],'failed');self.assertTrue((target/'discovered.json').is_file())
    def test_invalid_roots_cwd_errors_and_metadata(self):
        good=self.listing()
        bad=[None,[],{}, {'data':[]}, {'data':[good['data'][0]]*2}]
        for field,value in [('cwd','relative'),('errors',[{'message':'invalid skill'}]),('skills',[])]:
            v=json.loads(json.dumps(good));v['data'][0][field]=value;bad.append(v)
        for field,value in [('enabled',1),('path','relative/SKILL.md'),('scope','unknown')]:
            v=json.loads(json.dumps(good));v['data'][0]['skills'][0][field]=value;bad.append(v)
        v=json.loads(json.dumps(good));v['data'][0]['skills'].append(v['data'][0]['skills'][0]);bad.append(v)
        for value in bad:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):skill_listing(value,self.root)
        self.assertEqual(len(skill_listing(good,self.root)),3)
    def test_selected_file_overrides_old_disabled_entry(self):
        text=skill_configuration(self.skill,[{'path':self.selected['path'],'enabled':False}])
        self.assertEqual(text.count('SKILL.md'),1);self.assertIn('enabled=true',text)
    def test_unselected_read_detection_handles_cli_display_quoting(self):
        path=self.user['path'];disabled=[{'path':path,'enabled':False}]
        for quoted in (path,path.replace('\\','\\\\')):
            events=[{'type':'item.completed','item':{'type':'command_execution','command':'Get-Content "'+quoted+'"'}}]
            self.assertTrue(unselected_skill_reads(events,disabled))
        events=[{'type':'item.completed','item':{'type':'command_execution','command':'Get-Content "'+self.selected['path']+'"'}}]
        self.assertFalse(unselected_skill_reads(events,disabled))
    def fake(self,body):
        script=self.root/'fake_server.py';script.write_text(body,encoding='utf-8');return [sys.executable,'-B',str(script)]
    def test_real_stdio_exchange_and_shutdown(self):
        command=self.fake('import sys,json\nfor line in sys.stdin:\n q=json.loads(line)\n if q["method"]=="initialize": print(json.dumps({"id":q["id"],"result":{}}),flush=True)\n elif q["method"]=="skills/list":\n  assert q["params"]=={"cwds":[sys.argv[1]],"forceReload":True}\n  print(json.dumps({"id":q["id"],"result":{"data":[]}}),flush=True)\n')
        self.assertEqual(request_skills(command+[str(self.root)],str(self.root),3),{'data':[]})
    def test_protocol_error_malformed_output_and_timeout(self):
        for body in ('print("[]",flush=True)\n','print("broken",flush=True)\n','import sys,json\nq=json.loads(sys.stdin.readline());print(json.dumps({"id":q["id"],"error":{"code":1}}),flush=True)\n','import time\ntime.sleep(10)\n'):
            with self.subTest(body=body):
                with self.assertRaises((RuntimeError,subprocess.SubprocessError)):request_skills(self.fake(body),str(self.root),.3)


if __name__=='__main__':unittest.main()
