"""Offline regression tests: all credentials, rc files and HTTP responses are fake."""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.auth = self.base / 'auth.json'
        self.pool = self.base / 'pool.json'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, CURRENT_AUTH_FILE=str(self.auth),
                        TMPDIR=str(self.base), PATH=f'{self.bin}:' + os.environ['PATH'])
        self.account = {'auth_mode': 'chatgpt', 'tokens': {
            'account_id': 'test-account', 'access_token': 'secret-access-token',
            'refresh_token': 'secret-refresh-token'}}
        self.auth.write_text(json.dumps(self.account))
        self.fake_curl = self.bin / 'curl'
        self.fake_curl.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == '-q'
assert not any('secret-' in a for a in args), args
if '-H' in args:
    assert '-L' not in args
    assert '--max-time' in args and '--connect-timeout' in args
    headers = sys.stdin.read()
    assert 'Authorization: Bearer secret-access-token' in headers
    assert 'ChatGPT-Account-Id: test-account' in headers
    body = os.environ.get('TEST_BODY', '{"email":"test@example.com","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":29}}}')
    Path(args[args.index('-o') + 1]).write_text(body)
    sys.stdout.write(os.environ.get('TEST_HTTP', '200'))
    sys.exit(int(os.environ.get('TEST_CURL_EXIT', '0')))
sys.exit(22)
''')
        self.fake_curl.chmod(0o755)
        jq = subprocess.check_output(['which', 'jq'], text=True).strip()
        # Also catch accidental secrets in jq arguments, including entire raw_auth.
        (self.bin / 'jq').write_text(f'''#!/usr/bin/env python3
import os, sys
assert not any('secret-' in a for a in sys.argv[1:]), sys.argv
os.execv({jq!r}, [{jq!r}] + sys.argv[1:])
''')
        (self.bin / 'jq').chmod(0o755)

    def run_usage(self, *args):
        return subprocess.run(['bash', str(ROOT / 'show_codex_usage.sh'), *args,
                               str(self.pool)], env=self.env, text=True,
                              capture_output=True, timeout=15)

    def assert_clean(self):
        self.assertFalse(list(self.base.glob('tmp.*')))
        self.assertFalse(list(self.base.glob('*.tmp.*')))
        self.assertFalse(Path(str(self.pool) + '.lock').exists())

    def test_usage_upsert_permissions_and_no_secret_arguments(self):
        for _ in range(2):
            result = self.run_usage()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('71%', result.stdout)
            self.assertNotIn('secret-', result.stdout + result.stderr)
            self.assertEqual(json.loads(self.pool.read_text()), [self.account])
            self.assertEqual(self.pool.stat().st_mode & 0o777, 0o600)
            self.assert_clean()

    def test_api_key_stays_local_and_is_redacted(self):
        self.auth.write_text(json.dumps({'OPENAI_API_KEY': 'secret-api-key'}))
        self.fake_curl.write_text('#!/bin/sh\nexit 99\n')
        result = self.run_usage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('usage check skipped', result.stdout)
        self.assertNotIn('secret-', result.stdout + result.stderr)
        self.assertNotIn('\x1b', result.stdout)
        self.assert_clean()

    def test_existing_lock_blocks_update_and_is_not_removed(self):
        lock = Path(str(self.pool) + '.lock')
        lock.mkdir()
        self.pool.write_text('[]')
        result = self.run_usage()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.pool.read_text(), '[]')
        self.assertTrue(lock.is_dir())

    def test_invalid_pool_is_preserved(self):
        for body in ('{}', '[null]', '[{"auth_mode":"chatgpt"}]', '[] []'):
            self.pool.write_text(body)
            result = self.run_usage()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.pool.read_text(), body)
            self.assert_clean()

    def test_header_injection_rejected_before_network(self):
        self.account['tokens']['access_token'] = 'secret-access-token\r\nX-Evil: yes'
        self.auth.write_text(json.dumps(self.account))
        self.assertNotEqual(self.run_usage().returncode, 0)
        self.assertFalse(self.pool.exists())
        self.assert_clean()

    def test_symlink_and_same_file_rejected(self):
        original = self.auth.read_bytes()
        self.pool.symlink_to(self.auth)
        self.assertNotEqual(self.run_usage().returncode, 0)
        self.pool.unlink()
        self.pool.hardlink_to(self.auth)
        self.assertNotEqual(self.run_usage().returncode, 0)
        self.assertEqual(self.auth.read_bytes(), original)

    def test_noninteractive_switch_does_not_write(self):
        original = self.auth.read_bytes()
        self.assertNotEqual(self.run_usage('switch').returncode, 0)
        self.assertEqual(self.auth.read_bytes(), original)
        self.assertFalse(self.pool.exists())

    def test_network_and_invalid_response_errors(self):
        for updates, expected in [({'TEST_HTTP': '401'}, 'HTTP 401'),
                                  ({'TEST_CURL_EXIT': '28'}, 'Network error'),
                                  ({'TEST_BODY': '<html>error</html>'}, 'invalid response'),
                                  ({'TEST_BODY': '[]'}, 'invalid response')]:
            previous = self.env.copy()
            self.env.update(updates)
            result = self.run_usage()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)
            self.env = previous
            self.assert_clean()

    def test_terminal_controls_are_filtered(self):
        self.env['TEST_BODY'] = json.dumps({'email': 'bad\x1b]52;c;data\x07', 'plan_type': 'x\\033[2J'})
        result = self.run_usage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('\x1b]52', result.stdout)
        self.assertIn('x\\033[2J', result.stdout)

    def test_interactive_switch_arrows_and_private_atomic_write(self):
        self.pool.write_text(json.dumps([{'OPENAI_API_KEY': 'secret-another-key'}]))
        master, slave = pty.openpty()
        process = subprocess.Popen(['bash', str(ROOT / 'show_codex_usage.sh'), 'switch', str(self.pool)],
                                   env=self.env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            output = b''
            deadline = time.monotonic() + 15
            while b'Auth pool file:' not in output and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    output += os.read(master, 65536)
            self.assertIn(b'Auth pool file:', output)
            # Up at the first row used to exit under set -e.
            os.write(master, b'\x1b[A\x1b[B\r')
            process.wait(timeout=10)
            self.assertEqual(process.returncode, 0, output.decode(errors='replace'))
            self.assertEqual(json.loads(self.auth.read_text()), {'OPENAI_API_KEY': 'secret-another-key'})
            self.assertEqual(self.auth.stat().st_mode & 0o777, 0o600)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
        self.assert_clean()

    def install(self, **overrides):
        env = dict(self.env, SHOW_CODEX_USAGE_INSTALL_DIR=str(self.base / 'installed'),
                   SHOW_CODEX_USAGE_RC_FILE=str(self.base / 'shellrc'))
        env.update(overrides)
        return subprocess.run(['bash', str(ROOT / 'install.sh')], env=env,
                              capture_output=True, text=True, timeout=10)

    def test_local_install_and_safe_rc_quoting(self):
        directory = self.base / "dir ' $(touch INJECTED) `touch INJECTED2`"
        for _ in range(2):
            result = self.install(SHOW_CODEX_USAGE_INSTALL_DIR=str(directory))
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((directory / 'show-codex-usage').read_bytes(), (ROOT / 'show_codex_usage.sh').read_bytes())
        rc = self.base / 'shellrc'
        self.assertEqual(rc.read_text().count('# >>> show-codex-usage >>>'), 1)
        result = subprocess.run(['bash', '-c', 'source "$1"; printf "%s" "$PATH"', 'test', str(rc)],
                                env=self.env, cwd=self.base, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith(str(directory) + ':'))
        self.assertFalse((self.base / 'INJECTED').exists())
        self.assertFalse((self.base / 'INJECTED2').exists())

    def test_invalid_installer_names_rejected(self):
        for name in ('x;touch INJECTED', '../outside', "bad'quote"):
            self.assertNotEqual(self.install(SHOW_CODEX_USAGE_COMMAND_NAME=name).returncode, 0)
        self.assertFalse((self.base / 'shellrc').exists())

    def test_failed_download_preserves_existing_installation(self):
        target = self.base / 'installed' / 'show-codex-usage'
        target.parent.mkdir()
        target.write_text('existing version')
        result = self.install(SHOW_CODEX_USAGE_SOURCE_URL='https://example.invalid/test.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), 'existing version')
        self.assertFalse(list(target.parent.glob('*.tmp.*')))


if __name__ == '__main__':
    unittest.main()
