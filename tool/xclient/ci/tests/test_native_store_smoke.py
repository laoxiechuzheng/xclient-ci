import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[4]
spec = importlib.util.spec_from_file_location('smoke', ROOT / 'tool/xclient/ci/native_store_smoke.py')
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)

class LauncherTests(unittest.TestCase):
    def test_local_guard_refuses_before_creating_output(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(smoke.Refused, 'github_hosted_ci_required'):
                smoke.ci_identity('windows')
    def test_compiled_defines_require_exact_single_values(self):
        expected={'SAFE_MODE':'true','XC_BRAND_ID':'example','XC_NATIVE_STORE_QA':'true'}
        encode=lambda rows: ','.join(base64.b64encode(value.encode()).decode() for value in rows)
        smoke.verify_defines(encode([key+'='+value for key,value in expected.items()]),expected)
        for rows in [['SAFE_MODE=false','XC_BRAND_ID=example','XC_NATIVE_STORE_QA=true'],['SAFE_MODE=true','SAFE_MODE=true','XC_BRAND_ID=example','XC_NATIVE_STORE_QA=true']]:
            with self.assertRaises(smoke.Refused):smoke.verify_defines(encode(rows),expected)
    def test_actual_generated_config_forms_preserve_target_and_defines(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            file=Path(folder)/'config'
            file.write_text('  "FLUTTER_TARGET=C:\\\\repo\\\\test\\\\qa.dart"\n  "DART_DEFINES=YQ=="\n')
            self.assertEqual(smoke.config_values(file,'windows'),{'FLUTTER_TARGET':'C:\\repo\\test\\qa.dart','DART_DEFINES':'YQ=='})
            file.write_text('FLUTTER_TARGET=test/qa.dart\nDART_DEFINES=YQ==\n')
            self.assertEqual(smoke.config_values(file,'macos'),{'FLUTTER_TARGET':'test/qa.dart','DART_DEFINES':'YQ=='})
    def test_missing_native_checks_cannot_be_a_pass(self):
        with self.assertRaises(smoke.Refused):smoke.verify_result({'success':True,'error_classes':[]})
    def test_only_safe_true_fields_are_accepted(self):
        result={key:True for key in ['success','canonical_identity','write_read','reopen','replace','namespace_isolation','individual_delete','cleanup_attempted','cleanup_verified','native_window_visible','native_flutter_frame_saved']}
        result['error_classes']=[]
        smoke.verify_result(result)
        for key in ['canonical_identity','cleanup_verified']:
            failed=dict(result,**{key:False})
            with self.assertRaises(smoke.Refused):smoke.verify_result(failed)
        with self.assertRaises(smoke.Refused):smoke.verify_result(dict(result,extra='not-safe'))
    def test_output_cannot_escape_workspace_out(self):
        with self.assertRaises(smoke.Refused):smoke.scoped(ROOT/'test')
    @unittest.skipUnless(os.name=='nt','Windows process identity adapter only')
    def test_current_process_identity_uses_real_read_only_win32_api(self):
        import sys
        identity=smoke.process_identity(os.getpid())
        self.assertEqual(Path(identity['executable']),Path(sys.executable).resolve())
        self.assertGreater(identity['started'],0)

    def test_json_is_not_published_until_dump_completes(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            target=Path(folder)/'launch.json'
            original=smoke.json.dump
            def during_dump(data, stream, **options):
                self.assertFalse(target.exists())
                self.assertTrue(target.with_name('launch.json.next').exists())
                original(data, stream, **options)
                self.assertFalse(target.exists())
            with patch.object(smoke.json, 'dump', side_effect=during_dump):
                smoke.write_new(target, {'pid':123,'valid':True})
            self.assertEqual(json.loads(target.read_text(encoding='utf-8')),{'pid':123,'valid':True})
            self.assertFalse(target.with_name('launch.json.next').exists())
    def test_existing_json_is_never_replaced(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            target=Path(folder)/'launch.json'
            target.write_text('{"original":true}',encoding='utf-8')
            with self.assertRaises(FileExistsError):smoke.write_new(target,{'replacement':True})
            self.assertEqual(target.read_text(encoding='utf-8'),'{"original":true}')
    def test_generated_config_requests_utf8_independent_of_default_locale(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            file=Path(folder)/'config'
            file.write_text('FLUTTER_TARGET=test/测试.dart\nDART_DEFINES=YQ==\n',encoding='utf-8')
            original=Path.read_text
            def utf8_read(path,*args,**options):
                self.assertEqual(options.get('encoding'),'utf-8')
                return original(path,*args,**options)
            with patch.object(Path,'read_text',utf8_read):
                self.assertEqual(smoke.config_values(file,'macos')['FLUTTER_TARGET'],'test/测试.dart')
if __name__ == '__main__':
    unittest.main()
