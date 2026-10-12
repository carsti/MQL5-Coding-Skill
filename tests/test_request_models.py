"""Request model selection must not guess from saved defaults."""
from contextlib import redirect_stderr
from io import StringIO
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import yaml
from evaluate_workflows import REPO, codex_command, main

class RequestModels(unittest.TestCase):
    def test_missing_request_settings_cannot_borrow_saved_defaults(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            home=root/'home';home.mkdir()
            (home/'config.toml').write_text('model = "gpt-6-astra"\nmodel_reasoning_effort = "xhigh"\n')
            required=['--skill-root',str(root/'skill'),'--baseline-skill-root',str(root/'baseline'),'--mcp-package-root',str(root/'mcp'),'--codex-path',str(root/'codex.exe'),'--powershell',str(root/'pwsh.exe'),'--output',str(root/'output'),'--python',str(Path(os.sys.executable).resolve())]
            for selection in ([],['--model','gpt-6.1-sol'],['--reasoning-effort','medium'],['--model','  ','--reasoning-effort','medium'],['--model','gpt-6.1-sol','--reasoning-effort','  ']):
                with self.subTest(selection=selection),patch.dict(os.environ,{'CODEX_HOME':str(home)}),patch('evaluate_workflows.subprocess.check_output',side_effect=AssertionError('CLI must not start without request settings')) as launched,redirect_stderr(StringIO()):
                    with self.assertRaises(SystemExit) as result:main(required+selection)
                    self.assertEqual(result.exception.code,2)
                    launched.assert_not_called()

    def test_selected_request_settings_reach_each_cli_invocation(self):
        args=SimpleNamespace(codex_path=Path('C:/codex.exe'),mcp_package_root=Path('C:/mcp'))
        for model,effort in [('gpt-6.1-sol','medium'),('gpt-6-astra','low'),('future-model/custom','high')]:
            for phase in ('setup-preflight','baseline','candidate'):
                with self.subTest(model=model,phase=phase):
                    command=codex_command(args,Path('C:/workspace'),Path('C:/skill'),[],Path('C:/schema.json'),Path('C:/final.json'),phase,model,effort)
                    self.assertEqual(command.count('--model'),1)
                    self.assertEqual(command[command.index('--model')+1],model)
                    self.assertIn('model_reasoning_effort='+json.dumps(effort),command)
                    self.assertIn('--ignore-user-config',command)

    def test_hosted_workflow_has_no_named_model_or_effort_default(self):
        workflow=yaml.safe_load((REPO/'.github/workflows/workflow-evaluation.yml').read_text())
        inputs=workflow.get('on',workflow.get(True))['workflow_dispatch']['inputs']
        for name in ('model','reasoning_effort'):
            with self.subTest(name=name):
                self.assertTrue(inputs[name]['required'])
                self.assertNotIn('default',inputs[name])

    def test_explicit_model_preflight_keeps_authentication_isolated(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);home=root/'auth-home';home.mkdir()
            (home/'config.toml').write_text('Invalid TOML must never select a request model')
            authentication=b'{"synthetic_authentication":true}'
            (home/'auth.json').write_bytes(authentication)
            (home/'.codex-workflow-auth').mkdir()
            for name in ('skill','baseline'):
                path=root/name;path.mkdir()
                (path/'version.json').write_text('{"version":"1.2.2"}')
                (path/'SKILL.md').write_text('Synthetic selected skill')
            mcp=root/'mcp';revision='a'*64
            for name,data in {'package.json':'{"version":"1.3.8"}','app/server.mjs':'fixture','runtime/node.exe':'fixture','checksums.sha256':'fixture','data/active.json':json.dumps({'active_revision':revision}),'revisions/'+revision+'/manifest.json':json.dumps({'corpus_revision':'b'*64}),'revisions/'+revision+'/mql5-docs.sqlite':'fixture'}.items():
                path=mcp/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(data)
            for name in ('codex.exe','pwsh.exe'):(root/name).write_bytes(b'fixture')
            received=[]
            def preflight(args,result,disabled,environment,model,effort):
                isolated=Path(environment['CODEX_HOME'])
                self.assertNotEqual(isolated,home)
                self.assertEqual((isolated/'auth.json').read_bytes(),authentication)
                self.assertFalse((isolated/'config.toml').exists())
                received.append((model,effort));return True
            parameters=['--skill-root',str(root/'skill'),'--baseline-skill-root',str(root/'baseline'),'--mcp-package-root',str(mcp),'--codex-path',str(root/'codex.exe'),'--powershell',str(root/'pwsh.exe'),'--output',str(root/'output'),'--model','gpt-6.1-sol','--reasoning-effort','medium','--preflight-only']
            with patch.dict(os.environ,{'CODEX_HOME':str(home)}),patch('evaluate_workflows.Path.home',return_value=home),patch('evaluate_workflows.source_commit',return_value='c'*40),patch('evaluate_workflows.subprocess.check_output',side_effect=['codex-cli 0.162.1\n','--ignore-user-config --ephemeral --json --output-schema --output-last-message --sandbox']),patch('evaluate_workflows.subprocess.run'),patch('evaluate_workflows.run_preflight',side_effect=preflight):
                self.assertEqual(main(parameters),0)
            self.assertEqual(received,[('gpt-6.1-sol','medium')])
            self.assertEqual(list((home/'.codex-workflow-auth').iterdir()),[])

if __name__=='__main__':unittest.main()

