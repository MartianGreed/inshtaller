"""Black-box acceptance tests. Uses temporary homes and local Git backends only."""
import os
import json
import shlex
import sys
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = str(Path(__file__).resolve().parents[1] / 'zig-out/bin/insh')

class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='insh-test-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'home'
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), INSH_GITHUB_TOKEN='test', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
        for k in list(self.env):
            if k.startswith('INSH_') and k != 'INSH_GITHUB_TOKEN':
                del self.env[k]
        self.repo = Path(self.tmp.name) / 'backend.git'
        subprocess.run(['git', 'init', '--bare', '--initial-branch=main', str(self.repo)], check=True, capture_output=True)
        self.fixture('default', self.repo)

    def fixture(self, name, repo):
        p = self.home / '.inshtaller/profiles' / name
        p.mkdir(parents=True)
        (p / 'master.key').write_bytes(os.urandom(32))
        (p / 'github_token').write_text('test')
        (p / 'config.yaml').write_text(f'version: 1\nbackend:\n  repo: {repo}\nenv:\n')
        return p

    def run_insh(self, *args, value=None, ok=True, env=None):
        p = subprocess.run([BIN, *args], input=value, text=True, capture_output=True, env=env or self.env)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0)
        return p

    def add(self, key, value, ns=None, profile=None):
        args = ['add', '--type', 'env', '--key', key, '--stdin']
        if ns: args += ['-n', ns]
        if profile: args += ['--profile', profile]
        self.run_insh(*args, value=value)

    def test_namespaced_write_and_status(self):
        self.add('API_KEY', 'personal-secret')
        self.add('API_KEY', 'project-secret', 'project1')
        p = self.run_insh('status', '-n', 'project1')
        self.assertIn('project1', p.stdout)
        self.assertIn('API_KEY', p.stdout)
        self.assertNotIn('secret', p.stdout)

    def test_profiles_isolate_values(self):
        self.fixture('work', self.repo)
        self.add('PERSONAL', 'personal')
        self.add('WORK', 'work', profile='work')
        self.assertNotIn('WORK', self.run_insh('status').stdout)
        self.assertNotIn('PERSONAL', self.run_insh('status', '--profile', 'work').stdout)

    def shell_run(self, shell, steps, inherited=None):
        inspector = Path(self.tmp.name) / 'inspect.py'
        inspector.write_text("import os,json; print(json.dumps({k:os.environ.get(k) for k in ['API_KEY','ONLY_P1','ONLY_WORK','INSH_PROFILE','INSH_NAMESPACES','SPECIAL','EMPTY']}))")
        inspect = f'{shlex.quote(sys.executable)} {shlex.quote(str(inspector))}'
        if shell == 'nu': inspect = '^' + inspect
        steps = steps.replace('@inspect', inspect)
        if shell in ('bash', 'zsh'):
            script = f'eval "$({shlex.quote(BIN)} shell-init {shell})"\n' + steps
            argv = [shell, '--noprofile', '--norc', '-c', script] if shell == 'bash' else [shell, '-f', '-c', script]
        elif shell == 'fish':
            script = f'{shlex.quote(BIN)} shell-init fish | source\n' + steps
            argv = ['fish', '--no-config', '-c', script]
        else:
            integration = Path(self.tmp.name) / 'insh.nu'
            integration.write_text(self.run_insh('shell-init', 'nu').stdout)
            script_file = Path(self.tmp.name) / 'test.nu'
            script_file.write_text(f'source {shlex.quote(str(integration))}\n' + steps)
            argv = ['nu', '--no-config-file', str(script_file)]
        p = subprocess.run(argv, text=True, capture_output=True, env=dict(self.env, **(inherited or {})))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.last_shell_stderr = p.stderr
        return [json.loads(line) for line in p.stdout.splitlines() if line.startswith('{')]

    def test_shell_layer_switch_and_restore(self):
        self.add('API_KEY', 'personal')
        self.add('API_KEY', 'company', 'company')
        self.add('API_KEY', 'project', 'project1')
        self.add('ONLY_P1', 'p1', 'project1')
        self.add('SPECIAL', "quotes ' \\ \" $() `noexec`\nOTHER=part of value", 'project2')
        for shell in ['bash', 'zsh', 'fish', 'nu']:
            with self.subTest(shell=shell):
                result = self.shell_run(shell, """
@inspect
insh activate company project1
@inspect
insh activate project2
@inspect
insh deactivate
@inspect
""", {'API_KEY': 'local'})
                self.assertEqual(len(result), 4)
                self.assertEqual(result[0]['API_KEY'], 'personal')
                self.assertEqual(result[1]['API_KEY'], 'project')
                self.assertEqual(result[1]['ONLY_P1'], 'p1')
                self.assertEqual(result[2]['API_KEY'], 'personal')
                self.assertIsNone(result[2]['ONLY_P1'])
                self.assertEqual(result[2]['SPECIAL'], "quotes ' \\ \" $() `noexec`\nOTHER=part of value")
                self.assertEqual(result[3]['API_KEY'], 'local')
                self.assertIsNone(result[3]['SPECIAL'])

    def test_shell_manual_changes_and_profiles(self):
        self.fixture('work', self.repo)
        self.add('API_KEY', 'personal')
        self.add('API_KEY', 'project', 'project1')
        self.add('ONLY_P1', 'p1', 'project1')
        self.add('API_KEY', 'work', profile='work')
        self.add('ONLY_WORK', 'work', profile='work')
        for shell in ['bash', 'zsh', 'fish', 'nu']:
            with self.subTest(shell=shell):
                manual = {'bash': 'export ONLY_P1=manual', 'zsh': 'export ONLY_P1=manual', 'fish': 'set -gx ONLY_P1 manual', 'nu': '$env.ONLY_P1 = "manual"'}[shell]
                result = self.shell_run(shell, f"""
insh activate project1
{manual}
insh profile use work
@inspect
insh deactivate
@inspect
""", {'API_KEY': 'local'})
                self.assertEqual(result[0]['API_KEY'], 'work')
                self.assertEqual(result[0]['ONLY_P1'], 'manual')
                self.assertEqual(result[0]['INSH_PROFILE'], 'work')
                self.assertEqual(result[1]['API_KEY'], 'local')
                self.assertEqual(result[1]['ONLY_P1'], 'manual')
                self.assertIsNone(result[1]['ONLY_WORK'])

    def test_sync_keeps_other_machine_namespaces_and_explicit_removal(self):
        self.add('API_KEY', 'personal')
        self.add('API_KEY', 'project', 'project1')
        self.add('ONLY_P1', 'p1', 'project1')
        self.run_insh('sync')
        profile_a = self.home / '.inshtaller/profiles/default'
        home_b = Path(self.tmp.name) / 'home-b'
        profile_b = home_b / '.inshtaller/profiles/default'
        profile_b.mkdir(parents=True)
        for name in ['master.key', 'github_token', 'config.yaml']:
            shutil.copy2(profile_a / name, profile_b / name)
        env_b = dict(self.env, HOME=str(home_b))
        self.run_insh('sync', env=env_b)
        self.assertIn('ONLY_P1', self.run_insh('status', '-n', 'project1', env=env_b).stdout)
        self.run_insh('remove', '-n', 'project1', '--type', 'env', '--key', 'API_KEY')
        self.assertIn('API_KEY <- global', self.run_insh('status', '-n', 'project1').stdout)
        self.run_insh('sync')
        self.run_insh('sync', env=env_b)
        status = self.run_insh('status', '-n', 'project1', env=env_b).stdout
        self.assertIn('API_KEY <- global', status)
        self.assertIn('ONLY_P1', status)
        blob = subprocess.run(['git', '--git-dir', str(self.repo), 'show', 'HEAD:secrets.enc'], check=True, capture_output=True).stdout
        self.assertTrue(blob.startswith(b'INSH2\n'))
        self.assertNotIn(b'personal', blob)
        self.assertEqual(list((profile_a / 'pending').glob('*.enc')), [])

    def test_failed_push_keeps_pending_for_retry(self):
        self.add('API_KEY', 'personal', 'project1')
        hook = self.repo / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        self.run_insh('sync', ok=False)
        pending = self.home / '.inshtaller/profiles/default/pending'
        self.assertEqual(len(list(pending.glob('*.enc'))), 1)
        self.assertIn('API_KEY', self.run_insh('status', '-n', 'project1').stdout)
        hook.unlink()
        self.run_insh('sync')
        self.assertEqual(list(pending.glob('*.enc')), [])

    def test_migration_moves_existing_installation_without_changing_key(self):
        self.add('API_KEY', 'personal')
        profile = self.home / '.inshtaller/profiles/default'
        root = self.home / '.inshtaller'
        key = (profile / 'master.key').read_bytes()
        for name in ['config.yaml', 'master.key', 'github_token', 'pending']:
            shutil.move(str(profile / name), str(root / name))
        shutil.rmtree(root / 'profiles')
        self.assertIn('API_KEY', self.run_insh('status').stdout)
        self.assertEqual((profile / 'master.key').read_bytes(), key)
        self.assertFalse((root / 'config.yaml').exists())
        self.assertIn('API_KEY', self.run_insh('status').stdout)

    def test_unknown_namespace_and_profile_leave_shell_unchanged(self):
        self.add('API_KEY', 'project', 'project1')
        for shell in ['bash', 'zsh', 'fish', 'nu']:
            with self.subTest(shell=shell):
                bad = 'insh activate missing; insh profile use missing'
                if shell == 'nu': bad = 'try { insh activate missing }; try { insh profile use missing }'
                result = self.shell_run(shell, f'insh activate project1\n@inspect\n{bad}\n@inspect')
                self.assertEqual(result[0], result[1])
                self.assertEqual(result[1]['API_KEY'], 'project')

    def test_saved_defaults_and_explicit_profile_override(self):
        self.fixture('work', self.repo)
        self.add('API_KEY', 'work', profile='work')
        self.add('API_KEY', 'project', ns='project1', profile='work')
        self.run_insh('--profile', 'work', 'profile', 'defaults', 'project1')
        self.run_insh('profile', 'default', 'work')
        self.assertIn('API_KEY <- project1', self.run_insh('status').stdout)
        env = dict(self.env, INSH_PROFILE='default')
        self.run_insh('add', '--type', 'env', '--key', 'PERSONAL', '--stdin', value='x', env=env)
        self.assertIn('PERSONAL', self.run_insh('status', '--profile', 'default').stdout)
        self.assertNotIn('PERSONAL', self.run_insh('status').stdout)
        for shell in ['bash', 'zsh', 'fish', 'nu']:
            with self.subTest(shell=shell):
                r = self.shell_run(shell, '@inspect')
                self.assertEqual(r[0]['INSH_PROFILE'], 'work')
                self.assertEqual(r[0]['API_KEY'], 'project')

    def test_manual_unset_empty_original_and_explicit_activation(self):
        self.add('API_KEY', 'personal')
        self.add('API_KEY', 'project', 'project1')
        self.add('ONLY_P1', 'p1', 'project1')
        for shell in ['bash', 'zsh', 'fish', 'nu']:
            with self.subTest(shell=shell):
                manual = {'bash': 'export API_KEY=debug; unset ONLY_P1', 'zsh': 'export API_KEY=debug; unset ONLY_P1', 'fish': 'set -gx API_KEY debug; set -e ONLY_P1', 'nu': '$env.API_KEY = "debug"; hide-env ONLY_P1'}[shell]
                result = self.shell_run(shell, f"""
insh activate project1
{manual}
insh deactivate
@inspect
insh activate project1
@inspect
insh deactivate
@inspect
""", {'API_KEY': ''})
                self.assertEqual(result[0]['API_KEY'], 'debug')
                self.assertIsNone(result[0]['ONLY_P1'])
                self.assertEqual(result[1]['API_KEY'], 'project')
                self.assertEqual(result[2]['API_KEY'], 'debug')
                self.assertIsNone(result[2]['ONLY_P1'])
                clean = self.shell_run(shell, 'insh deactivate\n@inspect', {'API_KEY': ''})
                self.assertEqual(clean[0]['API_KEY'], '')

    def test_corrupt_pending_and_wrong_key_fail_without_consuming_changes(self):
        self.add('API_KEY', 'project', 'project1')
        p = self.home / '.inshtaller/profiles/default'
        staged = next((p / 'pending').glob('*.enc'))
        blob = staged.read_bytes()
        staged.write_bytes(blob[:-1] + bytes([blob[-1] ^ 1]))
        failure = self.run_insh('status', '-n', 'project1', ok=False)
        self.assertEqual(failure.stdout, '')
        self.assertIn('AuthenticationFailed', failure.stderr)
        self.assertTrue(staged.exists())
        staged.write_bytes(blob)
        (p / 'master.key').write_bytes(os.urandom(32))
        self.run_insh('sync', ok=False)
        self.assertEqual(staged.read_bytes(), blob)

    def test_profile_remote_mismatch_refuses_sync(self):
        self.add('API_KEY', 'personal')
        self.run_insh('sync')
        cfg = self.home / '.inshtaller/profiles/default/config.yaml'
        cfg.write_text(cfg.read_text().replace(str(self.repo), str(self.repo) + '-different'))
        failure = self.run_insh('sync', ok=False)
        self.assertIn('ProfileRepoMismatch', failure.stderr)

    def test_readonly_variable_rejects_whole_posix_transition(self):
        self.add('API_KEY', 'personal')
        self.add('API_KEY', 'project', 'project1')
        self.add('ZZ_LOCKED', 'new', 'project1')
        for shell in ['bash', 'zsh']:
            with self.subTest(shell=shell):
                result = self.shell_run(shell, 'readonly ZZ_LOCKED=old\n@inspect\ninsh activate project1\n@inspect')
                self.assertEqual(result[0], result[1])

    def test_invalid_names_and_reserved_keys_are_rejected(self):
        for name in ['../work', 'bad name', 'a:b', '-work']:
            self.run_insh('--profile', name, 'status', ok=False)
            self.run_insh('add', '-n', name, '--type', 'env', '--key', 'K', '--stdin', value='x', ok=False)
        for key in ['INSH_PROFILE', '__insh_code', '1BAD', 'PWD', 'status']:
            self.run_insh('add', '--type', 'env', '--key', key, '--stdin', value='x', ok=False)

    def test_profile_init_and_key_export_are_scoped(self):
        key_file = Path(self.tmp.name) / 'import.key'
        imported = os.urandom(32)
        key_file.write_bytes(imported)
        self.run_insh('profile', 'create', 'work', '--key-file', str(key_file), value=str(self.repo) + '\n')
        self.assertEqual(self.run_insh('--profile', 'work', 'export-key').stdout.strip(), imported.hex())
        self.assertNotEqual(self.run_insh('export-key').stdout.strip(), imported.hex())

    def test_shell_tracing_does_not_print_applied_values(self):
        secret = 'trace-must-never-see-this-synthetic-value'
        self.add('API_KEY', secret, 'project1')
        for shell in ['bash', 'zsh', 'fish']:
            with self.subTest(shell=shell):
                trace = 'set -g fish_trace 1' if shell == 'fish' else 'set -x'
                result = self.shell_run(shell, trace + '\ninsh activate project1\n@inspect')
                self.assertEqual(result[0]['API_KEY'], secret)
                self.assertNotIn(secret, self.last_shell_stderr)

    def test_home_override_keeps_profile_storage_reachable(self):
        self.add('HOME', '/synthetic-home', 'project1')
        self.add('API_KEY', 'project', 'project1')
        for shell in ['bash', 'zsh', 'fish', 'nu']:
            with self.subTest(shell=shell):
                result = self.shell_run(shell, 'insh activate project1\ninsh activate\n@inspect\ninsh deactivate\n@inspect')
                self.assertEqual(result[0]['API_KEY'], 'project')
                self.assertIsNone(result[1]['API_KEY'])

    def test_profile_lock_rejects_concurrent_commands(self):
        import fcntl
        lock = self.home / '.inshtaller/profiles/default/.lock'
        with lock.open('w') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            failed = self.run_insh('add', '--type', 'env', '--key', 'K', '--stdin', value='x', ok=False)
            self.assertIn('ProfileBusy', failed.stderr)
        self.add('K', 'x')

    def test_sync_discovers_remote_head_after_initial_empty_clone(self):
        self.add('API_KEY', 'personal')
        self.run_insh('sync')
        state = self.home / '.inshtaller/profiles/default/.state'
        probe = subprocess.run(['git', '-C', str(state), 'symbolic-ref', 'refs/remotes/origin/HEAD'], capture_output=True)
        if probe.returncode == 0:
            subprocess.run(['git', '-C', str(state), 'symbolic-ref', '--delete', 'refs/remotes/origin/HEAD'], check=True, capture_output=True)
        else:
            self.assertEqual(probe.returncode, 128)
        self.run_insh('sync')
        self.assertIn('API_KEY', self.run_insh('status').stdout)

    def test_child_shell_startup_restores_inherited_layers_before_defaults(self):
        self.add('API_KEY', 'personal')
        self.add('ONLY_P1', 'project', 'project1')
        dump = Path(self.tmp.name) / 'dump.py'
        dump.write_text('import json,os; print(json.dumps(dict(os.environ)))')
        for shell in ['bash', 'zsh', 'fish', 'nu']:
            with self.subTest(shell=shell):
                external = ('^' if shell == 'nu' else '') + shlex.quote(sys.executable) + ' ' + shlex.quote(str(dump))
                captured = self.shell_run(shell, 'insh activate project1\n' + external)[0]
                child = self.shell_run(shell, '@inspect', captured)[0]
                self.assertEqual(child['API_KEY'], 'personal')
                self.assertIsNone(child['ONLY_P1'])
                self.assertEqual(child['INSH_NAMESPACES'], '')

if __name__ == '__main__':
    unittest.main()
