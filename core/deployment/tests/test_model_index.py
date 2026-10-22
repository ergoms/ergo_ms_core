import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import _bootstrap  # noqa: F401
from model_index import ModelIndexError, build_index, install_models, resolve_local_model
from model_index.registry import discover_providers
from project_layout import huggingface_snapshot_dir

ROOT = Path(__file__).resolve().parents[3]


class ModelIndexTests(unittest.TestCase):
    def setUp(self):
        base = ROOT / 'virtual_env/cache/tmp'
        base.mkdir(parents=True, exist_ok=True)
        self.work = tempfile.TemporaryDirectory(dir=base, prefix='model_index_')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        (self.root / 'pyproject.toml').write_text('[tool.poetry]\n')
        self.consumer = self.root / 'modules/consumer'
        (self.consumer / 'api').mkdir(parents=True)
        (self.consumer / 'runtime_requirements.yaml').write_text('schema_version: 1\nmodule: consumer\nmodels:\n  - provider: huggingface\n    repo: team/model\n  - provider: huggingface\n    repo: team/optional\n    required: false\n')
        self.environment = patch.dict(os.environ, {'DISABLED_MODULES':'', 'MODULE_RUNTIME':'monolith', 'ERGO_PROCESS_ROLE':'', 'PROCESS_MODULES':''})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def ready(self, name='team/model'):
        dest = huggingface_snapshot_dir(self.root, name)
        dest.mkdir(parents=True, exist_ok=True)
        (dest / 'config.json').write_text('{}')
        (dest / 'model.safetensors').write_bytes(b'x' * 2048)
        return dest

    def provider(self, script='print("not json")', storage='virtual_env/trained_models/test'):
        module = self.root / 'modules/provider'
        (module / 'api').mkdir(parents=True)
        (module / 'adapter.py').write_text(script, encoding='utf-8')
        (module / 'model_providers.yaml').write_text(f'schema_version: 1\nmodule: provider\nproviders:\n  test:\n    script: adapter.py\n    storage: {storage}\n')
        return module

    def test_read_only_index_keeps_optional_missing_without_downloading(self):
        self.ready()
        with patch('model_index.registry.install_snapshot') as install:
            index = build_index(self.root)
            install.assert_not_called()
        self.assertEqual(index['schema_version'], 1)
        self.assertEqual([m['ready'] for m in index['models']], [True, False])

    def test_missing_model_does_not_fall_back_to_network_id(self):
        with patch('model_index.registry.install_snapshot') as install, self.assertRaises(ModelIndexError):
            resolve_local_model(self.root, 'huggingface', 'team/model')
        install.assert_not_called()

    def test_default_install_and_repeat_download_required_once(self):
        def download(root, name, **kwargs):
            self.ready(name)
            return 0
        with patch('model_index.registry.install_snapshot', side_effect=download) as install:
            first = install_models(self.root)
            second = install_models(self.root)
        self.assertEqual(first, second)
        self.assertEqual(install.call_count, 1)
        self.assertEqual(install.call_args.args[1], 'team/model')
        self.assertTrue((self.root / 'virtual_env/cache/model_index.json').is_file())
        self.assertFalse(huggingface_snapshot_dir(self.root, 'team/optional').exists())

    def test_optional_first_use_requires_explicit_permission(self):
        with self.assertRaises(ModelIndexError):
            resolve_local_model(self.root, 'huggingface', 'team/optional')
        with patch('model_index.registry.install_snapshot', side_effect=lambda root,name,**kw: (self.ready(name),0)[1]):
            reference = resolve_local_model(self.root, 'huggingface', 'team/optional', allow_download=True)
        self.assertTrue(reference['ready'])
        self.assertTrue(Path(reference['local_path']).is_dir())

    def test_success_code_with_incomplete_weights_is_rejected(self):
        with patch('model_index.registry.install_snapshot', return_value=0), self.assertRaises(ModelIndexError):
            resolve_local_model(self.root, 'huggingface', 'team/model', allow_download=True)

    def test_provider_bad_json_fails_closed(self):
        self.provider()
        with self.assertRaises(ModelIndexError):
            build_index(self.root)

    def test_provider_path_cannot_escape_its_module(self):
        module = self.provider()
        path = module / 'model_providers.yaml'
        path.write_text(path.read_text().replace('adapter.py', '../consumer/adapter.py'))
        with self.assertRaises(ModelIndexError):
            discover_providers(self.root)

    def test_provider_cannot_replace_builtin(self):
        module = self.provider()
        path = module / 'model_providers.yaml'
        path.write_text(path.read_text().replace('  test:', '  huggingface:'))
        with self.assertRaises(ModelIndexError):
            discover_providers(self.root)

    def test_provider_local_path_outside_storage_is_rejected(self):
        self.ready()
        raw = {'models':[{'name':'model', 'required':True, 'ready':True, 'local_path':str(self.root/'pyproject.toml')}]}
        self.provider('import json; print(json.dumps('+repr(raw)+'))')
        with self.assertRaises(ModelIndexError):
            build_index(self.root)

    def test_external_provider_real_subprocess_returns_verified_local_reference(self):
        dest = self.root / 'virtual_env/trained_models/test/model.bin'
        dest.parent.mkdir(parents=True)
        dest.write_bytes(b'local')
        raw = {'name':'model:latest', 'runtime_name':'model:latest', 'required':True, 'ready':True, 'local_path':str(dest)}
        self.provider('import json; print(json.dumps('+repr(raw)+'))')
        self.assertEqual(resolve_local_model(self.root, 'test', 'model')['local_path'], str(dest.resolve()))

    def test_external_provider_install_is_checked_and_not_repeated(self):
        self.provider('''import argparse,json
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('action'); parser.add_argument('--root'); parser.add_argument('--model',default='model')
args=parser.parse_args(); root=Path(args.root)
dest=root/'virtual_env/trained_models/test/model.bin'
counter=root/'installs'
if args.action=='install':
    dest.parent.mkdir(parents=True,exist_ok=True); dest.write_bytes(b'verified')
    counter.write_text(counter.read_text()+'1' if counter.exists() else '1')
record={'name':'model','required':True,'ready':dest.is_file(),'local_path':str(dest) if dest.is_file() else None}
print(json.dumps({'models':[record]} if args.action=='list' else record))
''')
        first = resolve_local_model(self.root,'test','model',allow_download=True)
        self.assertEqual(first,resolve_local_model(self.root,'test','model',allow_download=True))
        self.assertEqual((self.root/'installs').read_text(),'1')

    def test_missing_declared_provider_is_reported(self):
        with (self.consumer / 'runtime_requirements.yaml').open('a') as stream:
            stream.write('  - provider: ollama\n    name: tiny\n')
        missing = [row for row in build_index(self.root)['models'] if row['provider'] == 'ollama']
        self.assertEqual(missing[0]['reason'], 'provider_missing')
        self.assertFalse(missing[0]['ready'])

    def test_cli_check_missing_required_returns_json_and_nonzero(self):
        script = ROOT / 'core/deployment/model_index/cli.py'
        run = subprocess.run([sys.executable, str(script), 'check', '--root', str(self.root), '--json'], capture_output=True, text=True)
        self.assertEqual(run.returncode, 1, run.stderr)
        self.assertEqual(json.loads(run.stdout)['schema_version'], 1)
        self.assertNotIn('Traceback', run.stderr)

    def test_api_runtime_wrapper_resolves_without_django_initialization(self):
        self.ready()
        spec = importlib.util.spec_from_file_location('runtime_model_wrapper', ROOT/'core/api/src/core/utils/model_index.py')
        wrapper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(wrapper)
        self.assertTrue(wrapper.resolve_model('huggingface','team/model',root=self.root)['ready'])

    def test_model_verification_follows_module_setup_and_precedes_migrate(self):
        from lifecycle.recipes import RECIPE_REGISTRY
        steps = [step.name for step in RECIPE_REGISTRY['setup-full'].steps]
        self.assertLess(steps.index('module_setup_tasks'), steps.index('verify_required_models'))
        self.assertLess(steps.index('verify_required_models'), steps.index('migrate'))

    def test_docker_model_install_uses_existing_oneoff_runner(self):
        from lifecycle.steps.model_index_steps import InstallRuntimeModelsStep
        ctx = SimpleNamespace(runtime='docker',docker_mode='dev',project_root=self.root)
        with patch('lifecycle.steps.model_index_steps.docker_ops.run_api_oneoff',return_value=7) as run:
            result = InstallRuntimeModelsStep().run(ctx)
        self.assertEqual(result.exit_code, 7)
        self.assertIn('model_index/cli.py install --root /app', run.call_args.args[0])
        self.assertEqual(run.call_args.kwargs['project_root'],self.root)

    def test_json_install_keeps_legacy_downloader_messages_on_stderr(self):
        from contextlib import redirect_stdout, redirect_stderr
        import io
        from model_index.cli import main
        def download(root, name, **kwargs):
            print('legacy progress')
            self.ready(name)
            return 0
        output, errors = io.StringIO(), io.StringIO()
        with patch('model_index.registry.install_snapshot',side_effect=download), redirect_stdout(output), redirect_stderr(errors):
            self.assertEqual(main(['install','--root',str(self.root),'--json']), 0)
        self.assertIn('models',json.loads(output.getvalue()))
        self.assertIn('legacy progress',errors.getvalue())

    def test_cli_root_and_json_before_subcommand_are_preserved(self):
        from contextlib import redirect_stdout
        import io
        from model_index.cli import main
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(main(['--root',str(self.root),'--json','list']), 0)
        self.assertEqual(len(json.loads(output.getvalue())['models']), 2)
