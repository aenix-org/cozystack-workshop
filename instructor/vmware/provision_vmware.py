"""Local orchestration. No network or filesystem mutations in dry-run mode."""
import base64
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE
STATE = ROOT / 'state'
BASTION = 'ubuntu@95.217.173.146'
K = ['kubectl', '--kubeconfig', str(Path.home()/'workshop.txt'),
     '--context', 'admin@workshop', '--request-timeout=60s']


def run(args, data=None):
    # Never send command diagnostics or secret response bodies to the terminal.
    p = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True, timeout=1800)
    if p.returncode:
        raise RuntimeError('Operation failed: '+args[0]+' (diagnostics suppressed)')
    return p.stdout


def private(path, text):
    if path.is_symlink():
        raise RuntimeError('Refusing secret symlink')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())


def get(kind, name, ns):
    raw = run(K+['-n', ns, 'get', kind, name, '--ignore-not-found', '-o', 'json'])
    return json.loads(raw) if raw.strip() else None


def ensure(obj):
    meta = obj['metadata']
    old = get(obj['kind'], meta['name'], meta.get('namespace', 'default'))
    if old is None:
        run(K+['apply', '--validate=false', '-f', '-'], json.dumps(obj))
    else:
        # Preserve existing resources; reject drift rather than silently overwriting it.
        def contains(actual, desired):
            if isinstance(desired, dict):
                return isinstance(actual, dict) and all(
                    k in actual and contains(actual[k], v) for k, v in desired.items())
            return actual == desired
        if 'spec' in obj and not contains(old.get('spec', {}), obj['spec']):
            raise RuntimeError('Existing '+obj['kind']+' differs from required configuration')
        if 'stringData' in obj:
            for key, value in obj['stringData'].items():
                if base64.b64decode(old.get('data', {}).get(key, '')).decode() != value:
                    raise RuntimeError('Existing secret differs from saved state')


def wait(label, check, seconds=900):
    print('  Waiting for '+label, flush=True)
    end = time.monotonic()+seconds
    while time.monotonic() < end:
        try:
            if check():
                return
        except (RuntimeError, KeyError):
            pass
        time.sleep(10)
    raise RuntimeError('Timeout waiting for '+label)


def ready(kind, name, ns):
    obj = get(kind, name, ns)
    return bool(obj and any(c['type'] == 'Ready' and c['status'] == 'True'
                and c.get('observedGeneration', obj['metadata'].get('generation'))
                == obj['metadata'].get('generation')
                for c in obj.get('status', {}).get('conditions', [])))


def keycloak(u, password):
    import kc
    from urllib.parse import quote
    def api(method, path, body=None):
        status, response = kc.api(method, path, body)
        if status not in (200, 201, 204):
            raise RuntimeError('Keycloak HTTP '+str(status))
        return response
    name = 'tenant-'+u+'-super-admin'
    group = []
    def group_ready():
        group[:] = [g for g in api('GET', '/groups?search='+quote(name)+'&max=200')
                    if g['name'] == name]
        return bool(group)
    wait('Keycloak tenant group', group_ready)
    users = api('GET', '/users?username='+quote(u)+'&exact=true')
    if not users:
        api('POST', '/users', {'username': u, 'email': u+'@aenix.io',
            'emailVerified': True, 'enabled': True, 'firstName': 'Workshop',
            'lastName': u, 'requiredActions': [], 'credentials': [
                {'type': 'password', 'value': password, 'temporary': False}]})
        users = api('GET', '/users?username='+quote(u)+'&exact=true')
    uid = users[0]['id']
    groups = api('GET', '/users/'+uid+'/groups')
    if not any(g['id'] == group[0]['id'] for g in groups):
        api('PUT', '/users/'+uid+'/groups/'+group[0]['id'])


def remote_helpers():
    # Only source code is uploaded. Credentials travel through SSH stdin.
    directory = run(['ssh', BASTION, 'umask 077; mktemp -d /tmp/vmware-provision.XXXXXXXX']).strip()
    if not re.fullmatch(r'/tmp/vmware-provision\.[A-Za-z0-9]+', directory):
        raise RuntimeError('Invalid remote helper directory')
    run(['scp', str(HERE/'gitlab_api.py'), str(HERE/'gitlab_vmware.py'),
         str(HERE/'bastion-vmware.sh'), BASTION+':'+directory+'/'])
    return directory


WORKSHOP_RULES = [
    # Read generated credentials (bucket keys, database password) and run psql in the DB pod.
    {'apiGroups': [''], 'resources': ['secrets'], 'verbs': ['get', 'list']},
    {'apiGroups': [''], 'resources': ['pods/exec'], 'verbs': ['create']},
    # Publish the migrated application (written to Git, applied by Flux).
    {'apiGroups': [''], 'resources': ['services'],
     'verbs': ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete']},
    {'apiGroups': ['networking.k8s.io'], 'resources': ['ingresses'],
     'verbs': ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete']},
    # Look under the hood.
    {'apiGroups': ['helm.toolkit.fluxcd.io'], 'resources': ['helmreleases'], 'verbs': ['get', 'list', 'watch']},
    {'apiGroups': ['source.toolkit.fluxcd.io'], 'resources': ['gitrepositories'], 'verbs': ['get', 'list', 'watch']},
    {'apiGroups': ['kustomize.toolkit.fluxcd.io'], 'resources': ['kustomizations'], 'verbs': ['get', 'list', 'watch']},
    {'apiGroups': ['cdi.kubevirt.io'], 'resources': ['datavolumes'], 'verbs': ['get', 'list', 'watch']},
    {'apiGroups': ['postgresql.cnpg.io'], 'resources': ['clusters'], 'verbs': ['get', 'list', 'watch']},
    {'apiGroups': ['kafka.strimzi.io'], 'resources': ['kafkas', 'kafkatopics'], 'verbs': ['get', 'list', 'watch']},
    # Day two: watch the VM and live-migrate it.
    {'apiGroups': ['kubevirt.io'], 'resources': ['virtualmachines', 'virtualmachineinstances'],
     'verbs': ['get', 'list', 'watch']},
    {'apiGroups': ['kubevirt.io'], 'resources': ['virtualmachineinstancemigrations'],
     'verbs': ['get', 'list', 'watch', 'create']},
    {'apiGroups': ['subresources.kubevirt.io'], 'resources': ['virtualmachines/migrate'], 'verbs': ['update']},
]


def workshop_rbac(u):
    """Extra rights the workshop needs on top of the tenant roles, for the participant's
    Keycloak group and for the tenant service account Flux and the bastion use."""
    ns = 'tenant-'+u
    subjects = [{'kind': 'Group', 'apiGroup': 'rbac.authorization.k8s.io', 'name': ns+'-super-admin'},
                {'kind': 'ServiceAccount', 'name': ns, 'namespace': ns}]
    ensure({'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'Role',
            'metadata': {'name': 'workshop-vmware', 'namespace': ns}, 'rules': WORKSHOP_RULES})
    ensure({'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'RoleBinding',
            'metadata': {'name': 'workshop-vmware', 'namespace': ns},
            'roleRef': {'apiGroup': 'rbac.authorization.k8s.io', 'kind': 'Role', 'name': 'workshop-vmware'},
            'subjects': subjects})
    # Instance types and VM profiles are cluster-scoped; reading them helps pick a size.
    ensure({'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'ClusterRole',
            'metadata': {'name': 'workshop-vmware-instancetypes'},
            'rules': [{'apiGroups': ['instancetype.kubevirt.io'],
                       'resources': ['virtualmachineclusterinstancetypes', 'virtualmachineclusterpreferences'],
                       'verbs': ['get', 'list', 'watch']}]})
    ensure({'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'ClusterRoleBinding',
            'metadata': {'name': 'workshop-vmware-instancetypes-'+u},
            'roleRef': {'apiGroup': 'rbac.authorization.k8s.io', 'kind': 'ClusterRole',
                        'name': 'workshop-vmware-instancetypes'},
            'subjects': subjects})


def platform(u, password, remote):
    ns = 'tenant-'+u
    ensure({'apiVersion': 'apps.cozystack.io/v1alpha1', 'kind': 'Tenant',
        'metadata': {'name': u, 'namespace': 'tenant-root'},
        'spec': {'etcd': False, 'host': '', 'ingress': False,
                 'monitoring': False, 'seaweedfs': False,
                 'resourceQuotas': {'cpu': '40', 'memory': '48Gi'}}})
    wait('tenant Ready', lambda: ready('tenants.apps.cozystack.io', u, 'tenant-root'))
    wait('tenant service account', lambda: get('serviceaccount', ns, ns))
    workshop_rbac(u)
    keycloak(u, password)
    tokenfile = STATE/(u+'-flux.json')
    root_token = STATE/'gitlab-root-token.txt'
    if not root_token.exists():
        # A GitLab admin personal access token; point GITLAB_ROOT_TOKEN_FILE at it once.
        source = Path(os.environ.get('GITLAB_ROOT_TOKEN_FILE',
                                     str(Path.home()/'projects/fraud-workshop/state/gitlab-root-token.txt')))
        private(root_token, source.read_text())
    root_token.chmod(0o600)
    payload = {'login': u, 'password': password, 'root_token': root_token.read_text().strip(),
               'readme': (ROOT/'template/platform/README.md').read_text()}
    if tokenfile.exists():
        tokenfile.chmod(0o600)
        payload['flux'] = json.loads(tokenfile.read_text())
    output = run(['ssh', BASTION, 'PYTHONDONTWRITEBYTECODE=1 python3 '+remote+'/gitlab_vmware.py'],
                 json.dumps(payload))
    flux = json.loads(output)
    private(tokenfile, json.dumps(flux)+'\n')
    ensure({'apiVersion': 'v1', 'kind': 'Secret',
        'metadata': {'name': 'gitlab-flux', 'namespace': ns}, 'type': 'Opaque',
        'stringData': {'username': flux['username'], 'password': flux['token']}})
    ensure({'apiVersion': 'source.toolkit.fluxcd.io/v1', 'kind': 'GitRepository',
        'metadata': {'name': 'infra', 'namespace': ns},
        'spec': {'interval': '1m', 'url': 'https://gitlab.workshop.aenix.io/'+u+'/vmware-migration.git',
                 'ref': {'branch': 'main'}, 'secretRef': {'name': 'gitlab-flux'}}})
    ensure({'apiVersion': 'kustomize.toolkit.fluxcd.io/v1', 'kind': 'Kustomization',
        'metadata': {'name': 'platform', 'namespace': ns},
        'spec': {'interval': '1m', 'sourceRef': {'kind': 'GitRepository', 'name': 'infra'},
                 'path': './platform', 'prune': True, 'targetNamespace': ns,
                 'serviceAccountName': ns}})
    wait('Flux Kustomization Ready', lambda: ready('kustomizations.kustomize.toolkit.fluxcd.io', 'platform', ns))


def bastion(u, password, remote):
    ns = 'tenant-'+u
    wait('tenant service account', lambda: get('serviceaccount', ns, ns))
    # Persistent SA token, as in fraud access.yaml, using Cozystack's own SA.
    ensure({'apiVersion': 'v1', 'kind': 'Secret',
        'metadata': {'name': u+'-token', 'namespace': ns,
                     'annotations': {'kubernetes.io/service-account.name': ns}},
        'type': 'kubernetes.io/service-account-token'})
    wait('tenant service account token', lambda: get('secret', u+'-token', ns).get('data', {}).get('token'))
    secret = get('secret', u+'-token', ns)
    if secret['metadata']['annotations']['kubernetes.io/service-account.name'] != ns:
        raise RuntimeError('Existing token belongs to another service account')
    # Read only the selected admin context, then retain just its cluster endpoint/CA.
    ref = json.loads(run(K+['config', 'view', '--minify', '--flatten', '--raw', '-o', 'json']))
    cluster = ref['clusters'][0]['cluster']
    cfg = {'apiVersion': 'v1', 'kind': 'Config', 'current-context': 'tenant',
        'clusters': [{'name': 'platform', 'cluster': {
            'server': 'https://api.workshop.aenix.io:443', 'certificate-authority-data': cluster['certificate-authority-data']}}],
        'users': [{'name': u, 'user': {'token': base64.b64decode(secret['data']['token']).decode()}}],
        'contexts': [{'name': 'tenant', 'context': {'cluster': 'platform', 'user': u, 'namespace': ns}}]}
    private(STATE/(u+'.kubeconfig'), json.dumps(cfg, indent=2)+'\n')
    handout = (f'VMware to Cozystack workshop\n\nDashboard: https://dashboard.workshop.aenix.io/\n'
        f'Login: {u}\nPassword: {password}\nTenant: {ns}\n'
        f'GitLab: https://gitlab.workshop.aenix.io/{u}/vmware-migration\n'
        f'Bastion: ssh {u}@95.217.173.146 (same password)\n'
        'Materials: ~/workshop\nRepository: ~/vmware-migration\n'
        'Kubeconfig: ~/.kube/config; context: tenant\n')
    private(STATE/(u+'-handout.txt'), handout)
    # Explicit task exception to state-only storage: the Mac handout and bastion home.
    handout_path = Path.home()/u
    if not handout_path.exists():
        private(handout_path, handout)
    else:
        if handout_path.read_text() != handout:
            raise RuntimeError('Existing Mac handout differs; review saved state')
        handout_path.chmod(0o600)
    run(['ssh', BASTION, 'sudo bash '+remote+'/bastion-vmware.sh'], json.dumps({
        'login': u, 'password': password, 'kubeconfig': cfg, 'handout': handout,
        'ref': os.environ.get('WORKSHOP_REF', 'master')}))


def main():
    step = os.environ.get('STEP', 'all')
    dry = os.environ.get('DRY_RUN', '0')
    users = sys.argv[1:]
    if step not in ('platform', 'bastion', 'all') or dry not in ('0', '1'):
        raise RuntimeError('Use STEP=platform|bastion|all and DRY_RUN=0|1')
    if not users or any(not re.fullmatch(r'vmw[0-9]{1,29}', u) for u in users):
        raise RuntimeError('Usage: ./provision-vmware.sh vmw01 [vmw02 ...]')
    if dry == '1':
        for u in users:
            print(f'{u}: DRY RUN STEP={step}; no files, subprocesses or connections created')
            if step != 'bastion':
                print('  Tenant: monitoring=false, CPU=40, memory=48Gi; wait Ready; Keycloak cozy super-admin.')
                print('  GitLab via bastion/internal HTTP: user, vmware-migration/main, platform/README.md only.')
                print('  Reuse read_repository deploy token; Flux infra/platform: interval=1m, prune=true, SA=tenant-'+u+'.')
                print('  Wait Flux Ready. kubectl flags: --kubeconfig ~/workshop.txt --context admin@workshop --request-timeout=60s')
            if step != 'platform':
                print('  Check bastion tools; create user, clone repo/materials; tenant-only kubeconfig; private credentials.')
                print('  Mac handout: ~/'+u+' (600); secret state: '+str(STATE))
        return
    for tool in ('kubectl', 'ssh', 'scp'):
        if not shutil.which(tool):
            raise RuntimeError('Missing tool: '+tool)
    os.umask(0o077)
    STATE.mkdir(mode=0o700, exist_ok=True)
    STATE.chmod(0o700)
    for u in users:
        print(u+': provisioning '+step, flush=True)
        path = STATE/(u+'-password.txt')
        if not path.exists():
            if step == 'bastion':
                raise RuntimeError('Run platform first; saved password is missing')
            private(path, ''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789') for _ in range(20))+'\n')
        path.chmod(0o600)
        password = path.read_text().strip()
        if not password or any(c.isspace() or c == ':' for c in password):
            raise RuntimeError('Invalid saved password')
        # Fail early if required tools are unavailable; do not install software.
        run(['ssh', BASTION, 'command -v kubectl >/dev/null && command -v virtctl >/dev/null && command -v git >/dev/null && command -v python3 >/dev/null'])
        remote = remote_helpers()
        if step != 'bastion':
            platform(u, password, remote)
        if step != 'platform':
            bastion(u, password, remote)
        print(u+': '+step+' complete', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Exceptions from libraries can contain secrets; emit only our safe errors.
        print('ERROR: '+(str(exc) if type(exc) is RuntimeError else
                         'Provisioning failed; inspect saved state and resource status.'), file=sys.stderr)
        sys.exit(1)
