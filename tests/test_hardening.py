"""Offline regressions; never runs the real bootstrap command body."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class HardeningTests(unittest.TestCase):
    def test_hook_reads_stdin_and_legacy_environment(self):
        hook = ROOT / 'dotfiles/.claude/hooks/pr-reviewer-no-build.py'
        env = dict(os.environ, PR_REVIEWER_NO_BUILD='1')
        for payload in ({'tool_input': {'command': 'npm run build'}}, {'command': 'npm run build'}):
            result = subprocess.run(['python3', str(hook)], input=json.dumps(payload), text=True, env=env, capture_output=True)
            self.assertEqual(result.returncode, 2)
        env['CLAUDE_TOOL_INPUT'] = json.dumps({'command': 'pnpm build'})
        result = subprocess.run(['python3', str(hook)], input='', text=True, env=env, capture_output=True)
        self.assertEqual(result.returncode, 2)
        result = subprocess.run(['python3', str(hook)], input=json.dumps({'tool_input': {'command': 'git diff'}}), text=True, env=env, capture_output=True)
        self.assertEqual(result.returncode, 0)

    def test_invalid_user_rejected_before_commands(self):
        result = subprocess.run(['bash', str(ROOT / 'bootstrap.sh'), '--dry-run', '--user', 'bad;name'], text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('invalid --user', result.stderr)
        self.assertNotIn('apt-get', result.stdout)

    def install_functions(self):
        text = (ROOT / 'install.sh').read_text()
        return text[text.index('render()'):text.index('echo "==> dotfiles"')]

    def test_literal_render_and_shell_env_roundtrip(self):
        value = 'Name # & \\ " quote\nnext $(false)'
        with tempfile.TemporaryDirectory() as tmp:
            template = Path(tmp) / 'template.json'
            template.write_text('{"name": "__GIT_AUTHOR_NAME__"}')
            env = dict(os.environ, GIT_AUTHOR_NAME=value, GIT_AUTHOR_EMAIL='mail@example.com')
            result = subprocess.run(['bash', '-eu', '-c', self.install_functions() + '\nrender "$1"', '_', str(template)], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['name'], value)
            dest = Path(tmp) / '.env'
            result = subprocess.run(['bash', '-eu', '-c', self.install_functions() + '\nset_env "$1" SAMPLE "$GIT_AUTHOR_NAME"; . "$1"; printf %s "$SAMPLE"', '_', str(dest)], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, value)
            self.assertEqual(dest.stat().st_mode & 0o777, 0o600)

    def test_yaml_values_are_escaped(self):
        value = 'model" # & \\ \nnext: true'
        env = dict(os.environ, HERMES_MODEL=value, HERMES_MAX_SUBAGENTS='2')
        result = subprocess.run(['bash', '-eu', '-c', self.install_functions() + '\nhermes_config'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        line = next(line for line in result.stdout.splitlines() if line.startswith('  default:'))
        self.assertEqual(json.loads(line.split(': ', 1)[1]), value)

    def test_gateway_refuses_empty_allowlist(self):
        text = (ROOT / 'install.sh').read_text()
        start = text.index('UNITS=()')
        end = len(text)
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HOME=tmp, REPO_DIR=str(ROOT), WITH_HERMES='1', WITH_HERDR='0', WITH_SLED='1', TELEGRAM_ALLOWED_USERS='  , ', CALL_LOG=str(Path(tmp) / 'calls'))
            script = 'systemctl() { echo "$*" >> "$CALL_LOG"; }; place() { echo "place $2" >> "$CALL_LOG"; };\n' + text[start:end]
            result = subprocess.run(['bash', '-eu', '-c', script], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('TELEGRAM_ALLOWED_USERS is empty', result.stderr)
            calls = Path(env['CALL_LOG']).read_text()
            self.assertIn('enable sled.service', calls)
            self.assertIn('place ' + tmp + '/.config/systemd/user/hermes-gateway.service', calls)
            self.assertNotIn('enable hermes-gateway.service', calls)

    def test_dry_run_redacts_key_and_supports_security_flags(self):
        env = dict(os.environ, TAILSCALE_AUTHKEY='test-secret-placeholder')
        result = subprocess.run(['bash', str(ROOT / 'bootstrap.sh'), '--dry-run', '--admin-sudo', '--tailscale-only-ssh', '--automatic-reboot', '03:30'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(env['TAILSCALE_AUTHKEY'], result.stdout + result.stderr)
        self.assertIn('[REDACTED]', result.stdout)
        self.assertIn('tailscale0:22', result.stdout)

if __name__ == '__main__':
    unittest.main()
