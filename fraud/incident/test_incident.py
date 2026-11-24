"""All external commands are mocked; these tests never access a cluster or Git."""
import base64
from contextlib import redirect_stderr, redirect_stdout
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


loader = importlib.machinery.SourceFileLoader('incident', str(Path(__file__).with_name('incident')))
spec = importlib.util.spec_from_loader(loader.name, loader)
incident = importlib.util.module_from_spec(spec)
loader.exec_module(incident)


def deployment(cpu='500m', memory='1Gi', replicas=1, available=1):
    return {'spec': {'replicas': replicas, 'selector': {'matchLabels': {'app': 'explainer'}},
                     'template': {'spec': {'containers': [
                         {'resources': {'limits': {'cpu': cpu, 'memory': memory}}}]}}},
            'status': {'availableReplicas': available}}


def pod(name='explainer-abc', phase='Running', ready=True, labels=None):
    return {'metadata': {'name': name, 'labels': labels or {'app': 'explainer'}},
            'status': {'phase': phase, 'conditions': [
                {'type': 'Ready', 'status': 'True' if ready else 'False'}]}}


class IncidentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.platform = self.home / 'fraud-infra' / 'platform'
        self.platform.mkdir(parents=True)
        self.logs = self.home / 'logs'
        self.logs.mkdir()
        self.app = incident.Incident(self.home, self.logs)
        self.app.directory.mkdir()
        self.files = {
            'redis.yaml': 'kind: Redis\nmetadata:\n  name: features\nspec:\n  replicas: 1\n',
            'postgres.yaml': 'kind: Postgres\nspec:\n  users:\n    other:\n      password: keep\n    fraud:\n      password: "original # secret"\n',
            'switch-vm.yaml': 'kind: VirtualMachine\nspec:\n  runStrategy: Always\n',
        }
        for filename, source in self.files.items():
            (self.platform / filename).write_text(source)
        self.deployment = deployment()
        self.pods = []
        self.vmi = {'status': {'phase': 'Running'}}
        self.configmap = {'data': {'REDIS_ADDR': 'redis-features:6379'}}
        self.missing = set()
        self.fail = None
        self.runner = patch.object(incident.subprocess, 'run', side_effect=self.fake_run).start()
        self.popen = patch.object(incident.subprocess, 'Popen').start()
        self.addCleanup(patch.stopall)

    def fake_run(self, args, **kwargs):
        self.assertEqual(kwargs['stdout'], subprocess.PIPE)
        self.assertEqual(kwargs['stderr'], subprocess.PIPE)
        self.assertTrue(kwargs['text'])
        if self.fail and self.fail(args):
            return subprocess.CompletedProcess(args, 1, 'SECRET fault name', 'SECRET password')
        response = {}
        if args[0] == 'kubectl' and 'get' in args:
            index = args.index('get')
            resource = args[index + 1]
            if args[index + 2] in self.missing or resource in self.missing:
                return subprocess.CompletedProcess(args, 1, '', 'Error from server (NotFound): object not found')
            if resource == 'deployment':
                response = self.deployment
            elif resource == 'configmap':
                response = self.configmap
            elif resource == 'pods':
                response = {'items': self.pods}
            elif resource == 'vmi':
                response = self.vmi
        return subprocess.CompletedProcess(args, 0, json.dumps(response), 'suppressed')

    def execute(self, command):
        output = io.StringIO()
        with redirect_stdout(output):
            result = self.app.execute(command)
        return result, output.getvalue()

    def start(self, fault):
        with patch.object(incident.random, 'choice', return_value=fault) as choose:
            code, output = self.execute('start')
        self.assertIn(fault, choose.call_args.args[0])
        self.assertEqual(code, 0)
        self.assertEqual(output, incident.START_MESSAGE + '\n')
        self.assertNotIn(fault, output)
        return self.app.state['active']

    def read_state(self):
        return json.loads(base64.b64decode(self.app.state_file.read_bytes()))

    def test_default_start_and_help(self):
        with patch.object(incident, 'Incident', return_value=self.app):
            with patch.object(incident.random, 'choice', return_value='cases-stopped'):
                output = io.StringIO()
                with redirect_stdout(output):
                    self.assertEqual(incident.main([]), 0)
                self.assertEqual(output.getvalue(), incident.START_MESSAGE + '\n')
            with redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as raised:
                incident.main(['--help'])
            self.assertEqual(raised.exception.code, 0)

    def test_lifecycle_persistence_blindness_and_audit_log(self):
        self.start('cases-stopped')
        self.assertEqual(self.read_state()['active'], {'id': 'cases-stopped', 'hints': 0})
        self.assertEqual(self.app.state_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.execute('status'), (0, 'incident active, 0 hints used\n'))
        before = self.runner.call_count
        self.assertEqual(self.execute('start')[0], 1)
        self.assertEqual(self.runner.call_count, before)
        self.assertEqual(self.execute('reveal')[0], 1)
        for index, hint in enumerate(incident.FAULTS['cases-stopped']['hints'], 1):
            self.assertEqual(self.execute('hint'), (0, hint + '\n'))
            restored = incident.Incident(self.home, self.logs)
            restored.load()
            self.assertEqual(restored.state['active']['hints'], index)
        self.execute('hint')
        self.assertEqual(self.app.state['active']['hints'], 3)
        self.assertIn('cases-stopped:', self.execute('reveal')[1])
        self.assertEqual(self.execute('check'), (0, 'Fixed. Well done.\n'))
        self.assertEqual(self.execute('status'), (0, 'no active incident\n'))
        self.assertEqual(self.execute('list-done'), (0, 'cases-stopped\n'))
        state = self.read_state()
        self.assertIsNone(state['active'])
        self.assertEqual(state['used'], ['cases-stopped'])
        self.assertEqual(state['done'], ['cases-stopped'])
        log = next(self.logs.iterdir()).read_text().splitlines()
        self.assertEqual([line.split()[2] for line in log], ['start', 'hint', 'hint', 'hint', 'reveal', 'fixed'])
        self.assertTrue(all(line.endswith(' cases-stopped') for line in log))
        with patch.object(incident.random, 'choice', return_value='scorer-throttled') as choose:
            self.execute('start')
        self.assertNotIn('cases-stopped', choose.call_args.args[0])

    def test_no_active_commands(self):
        for command in ('hint', 'reveal', 'check'):
            self.assertEqual(self.execute(command), (1, 'no active incident\n'))
        self.assertEqual(self.execute('list-done'), (0, ''))
        self.assertEqual(self.runner.call_count, 0)

    def test_missing_prerequisites_and_exhaustion(self):
        for path in self.platform.iterdir():
            path.unlink()
        self.missing = {'explainer', 'cases'}
        with patch.object(incident.random, 'choice', return_value='scorer-throttled') as choose:
            self.execute('start')
        self.assertEqual(choose.call_args.args[0], ['redis-unreachable', 'scorer-throttled'])
        self.app.state['active'] = None
        self.app.state['used'].append('redis-unreachable')
        self.assertEqual(self.execute('start')[0], 1)

    def test_malformed_yaml_skipped(self):
        (self.platform / 'postgres.yaml').write_text('spec:\n  password: unrelated\n')
        self.assertFalse(self.app.eligible('db-password'))
        self.assertTrue(self.app.eligible('redis-unreachable'))

    def test_git_faults_commands_and_edits(self):
        for fault, filename, expected in (
            ('db-password', 'postgres.yaml', '      password: "random-secret"\n'),
            ('switch-halted', 'switch-vm.yaml', '  runStrategy: Halted\n'),
        ):
            with self.subTest(fault=fault):
                self.app.state['active'] = None
                self.runner.reset_mock()
                self.popen.reset_mock()
                with patch.object(incident.secrets, 'token_urlsafe', return_value='random-secret'):
                    active = self.start(fault)
                content = (self.platform / filename).read_text()
                self.assertIn(expected, content)
                if fault == 'db-password':
                    self.assertEqual(active['original'], 'original # secret')
                    self.assertIn('password: keep', content)
                if fault == 'switch-halted':
                    self.popen.assert_not_called()
                commands = [call.args[0] for call in self.runner.call_args_list if call.args[0][0] == 'git']
                self.assertEqual(commands, [
                    ['git', 'pull', '--rebase'],
                    ['git', 'add', '--', 'platform/' + filename],
                    ['git', 'commit', '-m', incident.FAULTS[fault]['commit'], '--', 'platform/' + filename],
                    ['git', 'push'],
                ])
                for call in self.runner.call_args_list:
                    if call.args[0][0] == 'git':
                        self.assertEqual(call.kwargs['cwd'], self.app.repo)

    def test_cases_pods_deleted_detached_and_scheduled_after_push(self):
        def after_push(*args, **kwargs):
            self.assertEqual(self.runner.call_args.args[0], ['git', 'push'])
        self.popen.side_effect = after_push
        self.start('db-password')
        self.popen.assert_called_once_with(
            ['nohup', 'sh', '-c', 'sleep 90 && exec kubectl --context fraud -n fraud delete pod -l app=cases --wait=false'],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )

    def test_explainer_lowers_memory_request_and_limit_together(self):
        self.start('explainer-oom')
        self.assertEqual(
            self.runner.call_args.args[0],
            ['kubectl', '--context', 'fraud', '-n', 'fraud', 'set', 'resources',
             'deploy/explainer', '--limits=memory=200Mi', '--requests=memory=200Mi'],
        )

    def test_cases_pods_not_deleted_if_push_fails(self):
        self.fail = lambda args: args == ['git', 'push']
        with self.assertRaises(incident.IncidentError):
            self.app.apply('db-password')
        self.popen.assert_not_called()

    def test_non_git_apply_commands(self):
        for fault in ('redis-unreachable', 'scorer-throttled', 'cases-stopped', 'explainer-oom'):
            with self.subTest(fault=fault):
                self.app.state['active'] = None
                self.start(fault)
                self.popen.assert_not_called()
                self.assertEqual(self.runner.call_args.args[0],
                                 ['kubectl', '--context', 'fraud', '-n', 'fraud'] + list(incident.FAULTS[fault]['apply']))

    def test_pull_happens_before_reading_original(self):
        original_runner = self.fake_run
        def concurrent_update(args, **kwargs):
            if args == ['git', 'pull', '--rebase']:
                path = self.platform / 'postgres.yaml'
                path.write_text(path.read_text().replace('original # secret', 'new upstream secret'))
            return original_runner(args, **kwargs)
        self.runner.side_effect = concurrent_update
        self.assertEqual(self.start('db-password')['original'], 'new upstream secret')

    def test_failure_is_generic_and_not_recorded(self):
        for failing_command in ('pull', 'commit', 'push', 'scale'):
            with self.subTest(command=failing_command):
                fault = 'cases-stopped' if failing_command == 'scale' else 'db-password'
                self.fail = lambda args: failing_command in args
                output, error = io.StringIO(), io.StringIO()
                with patch.dict(incident.os.environ, {'INCIDENT_DEBUG': '0'}), \
                     patch.object(incident, 'Incident', return_value=self.app), \
                     patch.object(incident.random, 'choice', return_value=fault), \
                     redirect_stdout(output), redirect_stderr(error):
                    self.assertEqual(incident.main(['start']), 1)
                self.assertEqual(output.getvalue(), '')
                self.assertEqual(error.getvalue(), 'Error: operation failed. Please try again.\n')
                self.assertIsNone(self.app.state['active'])
                self.assertFalse(self.app.state_file.exists())
                self.assertEqual(list(self.logs.iterdir()), [])
                self.popen.assert_not_called()

    def test_debug_reports_traceback_and_command_stderr(self):
        for failure in (subprocess.CompletedProcess(['git'], 1, '', 'Redis diagnostic'),
                        subprocess.TimeoutExpired('git', 120, stderr=b'timeout diagnostic'),
                        FileNotFoundError('missing executable')):
            with self.subTest(failure=failure):
                self.runner.side_effect = failure if isinstance(failure, Exception) else None
                self.runner.return_value = failure
                error = io.StringIO()
                with patch.dict(incident.os.environ, {'INCIDENT_DEBUG': '1'}), \
                     patch.object(incident, 'Incident', return_value=self.app), \
                     patch.object(self.app, 'execute', side_effect=lambda _: incident.run(['git', 'pull'])), \
                     redirect_stderr(error):
                    self.assertEqual(incident.main(['start']), 1)
                self.assertIn('Traceback (most recent call last)', error.getvalue())
                self.assertIn('IncidentError: Command failed.', error.getvalue())
                self.assertNotIn('operation failed', error.getvalue())
                expected = ('Redis diagnostic' if isinstance(failure, subprocess.CompletedProcess)
                            else 'timeout diagnostic' if isinstance(failure, subprocess.TimeoutExpired)
                            else 'missing executable')
                self.assertIn(expected, error.getvalue())

    def test_debug_reports_non_command_exception(self):
        error = io.StringIO()
        with patch.dict(incident.os.environ, {'INCIDENT_DEBUG': '1'}), \
             patch.object(incident, 'Incident', return_value=self.app), \
             patch.object(self.app, 'load', side_effect=ValueError('invalid state detail')), \
             redirect_stderr(error):
            self.assertEqual(incident.main(['status']), 1)
        self.assertIn('ValueError: invalid state detail', error.getvalue())
        self.assertIn('Traceback (most recent call last)', error.getvalue())

    def test_command_exceptions_are_wrapped(self):
        for failure in (FileNotFoundError(), subprocess.TimeoutExpired('kubectl', 120)):
            self.runner.side_effect = failure
            with self.assertRaises(incident.IncidentError):
                incident.kube('tenant', 'get', 'pods')

    def test_redis_override_command_and_check(self):
        active = self.start('redis-unreachable')
        self.assertEqual(self.runner.call_args.args[0],
                         ['kubectl', '--context', 'fraud', '-n', 'fraud', 'set', 'env',
                          'deploy/scorer', 'REDIS_ADDR=redis-features-cache:6379'])
        self.assertFalse(any(call.args[0][0] == 'git' for call in self.runner.call_args_list))
        self.popen.assert_not_called()
        container = self.deployment['spec']['template']['spec']['containers'][0]
        for env, fixed in (
            ([], True),
            ([{'name': 'OTHER', 'value': 'keep'}], True),
            ([{'name': 'REDIS_ADDR', 'value': 'redis-features-cache:6379'}], False),
            ([{'name': 'REDIS_ADDR', 'value': 'redis-features:6379'}], True),
            ([{'name': 'REDIS_ADDR', 'valueFrom': {'configMapKeyRef':
              {'name': 'other', 'key': 'REDIS_ADDR'}}}], False),
        ):
            with self.subTest(env=env):
                container['env'] = env
                self.assertEqual(self.app.fixed(active), fixed)
        container['env'] = [{'name': 'REDIS_ADDR', 'value': 'new-address:6379'}]
        self.configmap['data']['REDIS_ADDR'] = 'new-address:6379'
        self.assertTrue(self.app.fixed(active))
        self.configmap = {}
        self.assertFalse(self.app.fixed(active))
        self.deployment = {}
        self.assertFalse(self.app.fixed(active))

    def test_missing_objects_are_not_fixed(self):
        for fault, resource in (
            ('switch-halted', 'vmi'), ('redis-unreachable', 'scorer'),
            ('redis-unreachable', 'endpoints'), ('scorer-throttled', 'scorer'),
            ('cases-stopped', 'cases'), ('explainer-oom', 'explainer'),
            ('explainer-oom', 'pods'),
        ):
            with self.subTest(fault=fault, resource=resource):
                active = {'id': fault, 'hints': 0}
                self.app.state['active'] = active
                self.app.save()
                self.deployment['spec']['template']['spec']['containers'][0]['env'] = [
                    {'name': 'REDIS_ADDR', 'value': 'redis-features:6379'}]
                self.pods = [pod()]
                self.missing = {resource}
                self.assertEqual(self.execute('check'), (1, 'Not fixed yet.\n'))
                self.assertEqual(self.read_state()['active'], active)

    def test_checks_preserve_other_command_errors(self):
        for stderr in ('Error from server (Forbidden)', 'connection refused', 'Not found'):
            with self.subTest(stderr=stderr):
                self.runner.side_effect = None
                self.runner.return_value = subprocess.CompletedProcess([], 1, '', stderr)
                with self.assertRaises(incident.IncidentError):
                    self.app.fixed({'id': 'switch-halted'})
        self.runner.return_value = subprocess.CompletedProcess([], 0, 'invalid json', '')
        with self.assertRaises(incident.IncidentError):
            self.app.fixed({'id': 'scorer-throttled'})

    def test_database_check_compares_original_value(self):
        active = self.start('db-password')
        self.assertFalse(self.app.fixed(active))
        path = self.platform / 'postgres.yaml'
        path.write_text(self.files['postgres.yaml'].replace('"original # secret"', "'original # secret' # restored"))
        self.assertTrue(self.app.fixed(active))

    def test_switch_check_requires_always_and_running(self):
        active = self.start('switch-halted')
        self.assertFalse(self.app.fixed(active))
        (self.platform / 'switch-vm.yaml').write_text(self.files['switch-vm.yaml'])
        self.vmi = {'status': {'phase': 'Pending'}}
        self.assertFalse(self.app.fixed(active))
        self.vmi = {'status': {'phase': 'Running'}}
        self.assertTrue(self.app.fixed(active))
        self.assertEqual(self.runner.call_args.args[0], ['kubectl', '--context', 'tenant', 'get', 'vmi', 'vm-instance-switch', '-o', 'json'])

    def test_cpu_threshold(self):
        active = self.start('scorer-throttled')
        for value, fixed in (('30m', False), ('499m', False), ('500m', True), ('0.5', True), ('1', True), ('invalid', False)):
            with self.subTest(value=value):
                self.deployment = deployment(cpu=value)
                self.assertEqual(self.app.fixed(active), fixed)

    def test_cases_requires_replicas_and_availability(self):
        active = self.start('cases-stopped')
        for replicas, available, fixed in ((0, 0, False), (1, 0, False), (0, 1, False), (1, 1, True)):
            self.deployment = deployment(replicas=replicas, available=available)
            self.assertEqual(self.app.fixed(active), fixed)
        self.deployment = deployment(replicas=0)
        self.assertEqual(self.execute('check'), (1, 'Not fixed yet.\n'))
        self.assertEqual(self.read_state()['active'], active)

    def test_explainer_requires_memory_and_own_ready_pod(self):
        active = self.start('explainer-oom')
        self.pods = [pod()]
        for memory, fixed in (('200Mi', False), ('1G', False), ('1024Mi', True), ('1Gi', True), ('1073741824', True)):
            self.deployment = deployment(memory=memory)
            self.assertEqual(self.app.fixed(active), fixed)
        for pods in ([], [pod(ready=False)], [pod(labels={'app': 'other'})]):
            self.pods = pods
            self.assertFalse(self.app.fixed(active))
        self.pods = [pod()]
        self.pods[0]['metadata']['deletionTimestamp'] = 'now'
        self.assertFalse(self.app.fixed(active))

    def test_bad_state_fails_without_commands(self):
        for content in (b'not base64', base64.b64encode(b'{}'), base64.b64encode(b'{"active":null,"used":{},"done":[]}')):
            self.app.state_file.write_bytes(content)
            with self.assertRaises(incident.IncidentError):
                self.app.load()
        self.assertEqual(self.runner.call_count, 0)

    def test_optional_log_failure_is_silent(self):
        self.app.log_dir = self.home / 'missing'
        self.start('cases-stopped')
        with patch.object(Path, 'open', side_effect=PermissionError):
            self.app.log('hint', 'cases-stopped')


class TextAndQuantityTests(unittest.TestCase):
    def test_real_switch_manifest_changes_exactly_one_line(self):
        source = Path(__file__).with_name('testdata-switch-vm.yaml').read_text()
        self.assertEqual(source.count('  runStrategy: Always\n'), 1)
        updated = incident.edit_field(source, ('spec', 'runStrategy'), 'Halted')
        self.assertEqual(updated, source.replace('  runStrategy: Always\n', '  runStrategy: Halted\n'))
        self.assertEqual(incident.field_value(updated, ('spec', 'runStrategy')), 'Halted')
        self.assertIn(('spec', 'runStrategy'), incident.fields(source))

    def test_first_document_with_path_wins_even_when_adding(self):
        source = ('---\nmetadata: {name: disk}\nspec:\n  storage: 20Gi\n'
                  '---\nmetadata: {name: switch}\nspec:\n  runStrategy: Always\n'
                  '---\nmetadata: {name: other}\nspec:\n  runStrategy: Always\n')
        for add in (False, True):
            self.assertEqual(incident.edit_field(source, ('spec', 'runStrategy'), 'Halted', add),
                             source.replace('runStrategy: Always', 'runStrategy: Halted', 1))
        self.assertEqual(incident.field_value(source, ('spec', 'runStrategy')), 'Always')

    def test_missing_path_does_not_combine_documents(self):
        source = 'spec:\n  users:\n    fraud:\n      other: keep\n---\npassword: secret\n'
        with self.assertRaises(incident.IncidentError):
            incident.edit_field(source, ('spec', 'users', 'fraud', 'password'), 'new')

    def test_edit_is_scoped_and_preserves_other_fields(self):
        source = 'metadata:\n  resourcesPreset: keep\nspec:\n  resourcesPreset: small # old\n  replicas: 2\n'
        updated = incident.edit_field(source, ('spec', 'resourcesPreset'), 'nano', True)
        self.assertEqual(updated, 'metadata:\n  resourcesPreset: keep\nspec:\n  resourcesPreset: nano\n  replicas: 2\n')

    def test_add_uses_existing_indentation_and_handles_eof(self):
        self.assertEqual(incident.edit_field('spec:\n    replicas: 1\n', ('spec', 'resourcesPreset'), 'nano', True),
                         'spec:\n    resourcesPreset: nano\n    replicas: 1\n')
        self.assertEqual(incident.edit_field('spec:', ('spec', 'resourcesPreset'), 'nano', True),
                         'spec:\n  resourcesPreset: nano\n')

    def test_unsupported_or_missing_yaml_fails(self):
        for source in ('metadata:\n  name: x\n', 'spec: {}\n',
                       'spec: |\n  resourcesPreset: old\n',
                       'spec:\n  resourcesPreset: |\n    old\n',
                       'spec:\n  resourcesPreset: old\n  resourcesPreset: other\n'):
            with self.subTest(source=source), self.assertRaises(incident.IncidentError):
                incident.edit_field(source, ('spec', 'resourcesPreset'), 'nano', True)
        with self.assertRaises(incident.IncidentError):
            incident.edit_field('spec:\n  other: keep\n', ('spec', 'runStrategy'), 'Halted')

    def test_string_values(self):
        for raw, value in (("'a''b#c' # note", "a'b#c"), ('"a\\nb#c" # note', 'a\nb#c'),
                           ('plain#password # note', 'plain#password')):
            self.assertEqual(incident.scalar(raw), value)

    def test_quantity_and_multiple_containers(self):
        self.assertEqual(incident.quantity('5e-1'), incident.quantity('500m'))
        self.assertEqual(incident.quantity('1Gi'), incident.quantity('1024Mi'))
        self.assertEqual(incident.quantity('1000000000n'), 1)
        self.assertEqual(incident.quantity('bad'), -1)
        dep = deployment()
        dep['spec']['template']['spec']['containers'].append({'resources': {'limits': {'cpu': '30m'}}})
        self.assertFalse(incident.limits_at_least(dep, 'cpu', 0.5))
        self.assertFalse(incident.limits_at_least({}, 'cpu', 0.5))

    def test_selector_expressions(self):
        self.assertTrue(incident.matches_selector({'app': 'x'}, {'matchExpressions': [{'key': 'app', 'operator': 'In', 'values': ['x']}]}))
        self.assertFalse(incident.matches_selector({}, {'matchExpressions': [{'key': 'app', 'operator': 'Exists'}]}))
        self.assertFalse(incident.matches_selector({'app': 'x'}, {}))


if __name__ == '__main__':
    unittest.main()
