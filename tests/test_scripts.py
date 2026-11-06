#!/usr/bin/env python3
"""Offline process-contract tests; binaries are test doubles, not real imports."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as f: f.write(json.dumps([name] + args) + '\n')
if os.environ.get('BLOCK_COMMAND') == name:
    pathlib.Path(os.environ['BLOCK_READY']).touch()
    deadline = time.monotonic() + 10
    while not pathlib.Path(os.environ['BLOCK_RELEASE']).exists():
        if time.monotonic() > deadline: sys.exit(10)
        time.sleep(.01)
if os.environ.get('FAIL_COMMAND') == name: sys.exit(7)
if name == 'psql':
    if '-c' in args or '-Atc' in args:
        sql = args[args.index('-c')+1] if '-c' in args else args[args.index('-Atc')+1]
        if 'pg_class' in sql: print(os.environ.get('DB_HAS_TABLES', 'f'))
        elif 'to_regclass' in sql: print(os.environ.get('HAS_SCHEMA', 't'))
        elif 'schema_version' in sql: print(os.environ.get('SCHEMA_VERSION', '2'))
    elif '-f' in args:
        if os.environ.get('FAIL_SQL') == '1': sys.exit(8)
    else:
        sys.stdin.read(); print(os.environ.get('DB_EXISTS', 'f'))
if name == 'curl': sys.exit(9)
if name == 'osm2pgsql-replication' and args[0] == 'update':
    hook = args[args.index('--post-processing') + 1]
    result = subprocess.run([hook, '2', '2024-01-02T00:00:00Z'])
    if result.returncode: sys.exit(result.returncode)
    pathlib.Path(os.environ['CHECKPOINT']).write_text('2')
'''

class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='osm scripts ')
        self.base = Path(self.temp.name)
        self.project = self.base / 'project with spaces'
        shutil.copytree(ROOT, self.project, ignore=shutil.ignore_patterns('.git', 'replication', '__pycache__'))
        self.bin = self.base / 'bin'; self.bin.mkdir()
        for name in ['psql', 'createdb', 'osm2pgsql', 'osm2pgsql-replication', 'curl']:
            p = self.bin / name; p.write_text(FAKE); p.chmod(0o755)
        self.log = self.base / 'calls.jsonl'
        self.input = self.base / 'tiny input.osm'; self.input.write_text('<osm version="0.6"/>')
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
                        CALL_LOG=str(self.log), CHECKPOINT=str(self.base/'checkpoint'),
                        TMPDIR=str(self.base), OSM_FILE=str(self.input), DB_NAME='isolated_test',
                        DB_USER='test', DB_HOST='localhost', DB_PORT='5432', INIT_REPLICATION='0', DOWNLOAD_OSM='0')
        self.env.pop('SQL_SCRIPT', None)
    def tearDown(self): self.temp.cleanup()
    def run_script(self, script, *args, success=True, **extra):
        result = subprocess.run(['bash', str(self.project/script), *args], env=dict(self.env, **extra),
                                cwd=self.base, text=True, capture_output=True)
        if success: self.assertEqual(result.returncode, 0, result.stderr)
        else: self.assertNotEqual(result.returncode, 0, result.stdout)
        return result
    def calls(self): return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
    def commands(self): return [call[0] for call in self.calls()]
    def test_import_from_another_directory_and_spaces(self):
        self.run_script('run_osm_import.sh', INIT_REPLICATION='1')
        calls = self.calls()
        self.assertIn('createdb', self.commands())
        osm = next(c for c in calls if c[0]=='osm2pgsql')
        self.assertIn('--style='+str(self.project/'main.lua'), osm)
        self.assertEqual(osm[-1], str(self.input))
        self.assertIn('--host', osm); self.assertIn('--port', osm)
        self.assertNotIn('-h', osm); self.assertNotIn('-p', osm)
        self.assertEqual(calls[-1][0:2], ['osm2pgsql-replication', 'init'])
        self.assertIn('https://download.geofabrik.de/europe/ukraine-updates', calls[-1])
        self.assertFalse(list(self.base.glob('*.lock')))
    def test_missing_input_does_not_download_or_touch_database(self):
        self.run_script('run_osm_import.sh', success=False, OSM_FILE=str(self.base/'missing.osm'))
        self.assertEqual(self.calls(), [])
    def test_failed_opt_in_download_does_not_touch_database(self):
        self.run_script('run_osm_import.sh', success=False, OSM_FILE=str(self.base/'missing.osm'), DOWNLOAD_OSM='1')
        self.assertEqual(self.commands(), ['curl'])
        self.assertFalse(list(self.base.glob('*.download.*')))
    def test_existing_database_is_not_overwritten(self):
        self.run_script('run_osm_import.sh', success=False, DB_EXISTS='t', DB_HAS_TABLES='t')
        self.assertNotIn('osm2pgsql', self.commands())
        self.assertNotIn('createdb', self.commands())
    def test_import_failure_stops_before_postprocessing(self):
        self.run_script('run_osm_import.sh', success=False, FAIL_COMMAND='osm2pgsql', INIT_REPLICATION='1')
        self.assertFalse(any('-f' in c for c in self.calls()))
        self.assertNotIn('osm2pgsql-replication', self.commands())
    def test_sql_failure_stops_before_replication_init(self):
        self.run_script('run_osm_import.sh', success=False, FAIL_SQL='1', INIT_REPLICATION='1')
        self.assertNotIn('osm2pgsql-replication', self.commands())
    def test_createdb_failure_stops_import(self):
        self.run_script('run_osm_import.sh', success=False, FAIL_COMMAND='createdb')
        self.assertNotIn('osm2pgsql', self.commands())
    def test_update_never_reinitializes_state(self):
        self.run_script('run_osm_update.sh')
        repl = [c for c in self.calls() if c[0]=='osm2pgsql-replication']
        self.assertEqual(len(repl), 1); self.assertEqual(repl[0][1], 'update')
        self.assertIn('--post-processing', repl[0])
        self.assertEqual((self.base/'checkpoint').read_text(), '2')
    def test_sql_failure_prevents_checkpoint_and_retry_works(self):
        self.run_script('run_osm_update.sh', success=False, FAIL_SQL='1')
        self.assertFalse((self.base/'checkpoint').exists())
        self.assertFalse(list(self.base.glob('*.lock')))
        self.run_script('run_osm_update.sh')
        self.assertEqual((self.base/'checkpoint').read_text(), '2')
    def test_legacy_database_is_rejected_before_update(self):
        self.run_script('run_osm_update.sh', success=False, HAS_SCHEMA='f')
        self.assertNotIn('osm2pgsql-replication', self.commands())
    def test_initialization_is_explicit(self):
        self.run_script('run_osm_update.sh', '--init')
        self.assertEqual(self.calls()[-1][0:2], ['osm2pgsql-replication', 'init'])
    def test_bad_arguments_fail_before_database_access(self):
        self.run_script('run_osm_update.sh', '--wrong', success=False)
        self.assertEqual(self.calls(), [])
        self.run_script('run_osm_update.sh', success=False, MAX_DIFF_SIZE='0')
        self.assertEqual(self.calls(), [])
    def test_import_database_check_error_is_not_success(self):
        self.run_script('run_osm_import.sh', success=False, FAIL_COMMAND='psql')
        self.assertNotIn('createdb', self.commands())
    def test_future_schema_is_rejected(self):
        self.run_script('run_osm_update.sh', success=False, SCHEMA_VERSION='99')
        self.assertNotIn('osm2pgsql-replication', self.commands())
    def test_replication_init_failure_propagates(self):
        self.run_script('run_osm_update.sh', '--init', success=False, FAIL_COMMAND='osm2pgsql-replication')
        self.assertFalse(list(self.base.glob('*.lock')))
    def test_concurrent_writer_is_rejected(self):
        ready, release = self.base/'ready', self.base/'release'
        env = dict(self.env, BLOCK_COMMAND='osm2pgsql', BLOCK_READY=str(ready), BLOCK_RELEASE=str(release))
        process = subprocess.Popen(['bash', str(self.project/'run_osm_import.sh')], env=env,
                                   cwd=self.base, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue(ready.exists(), 'Import did not reach blocking point')
            before = self.calls()
            result = self.run_script('run_osm_update.sh', success=False)
            self.assertIn('Another import/update is running', result.stderr)
            self.assertEqual(self.calls(), before)
        finally:
            release.touch()
            out, err = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, err)
        self.assertFalse(list(self.base.glob('*.lock')))
    def test_postprocess_passes_transaction_and_error_flags(self):
        self.run_script('scripts/postprocess.sh')
        call = self.calls()[-1]
        self.assertIn('--single-transaction', call); self.assertIn('ON_ERROR_STOP=1', call)

if __name__ == '__main__': unittest.main(verbosity=2)
