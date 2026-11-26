"""Runs on the bastion. Credentials arrive on stdin, never in arguments."""
import json
import sys
from urllib.parse import quote
from gitlab_api import GitLab, ProvisionError


def provision(data):
    u, password = data['login'], data['password']
    api = GitLab('http://gitlab.tenant-root.svc.cozy.local', data['root_token'])
    users = [x for x in api.list_all('/users', username=u) if x['username'] == u]
    if users:
        user = users[0]
    else:
        user = api.request('POST', '/users', {
            'username': u, 'email': u+'@workshop.aenix.io', 'name': 'Workshop '+u,
            'password': password, 'skip_confirmation': True})
    path = '/projects/'+quote(u+'/vmware-migration', safe='')
    project = api.request('GET', path, missing_ok=True)
    if project is None:
        project = api.request('POST', f"/projects/user/{user['id']}", {
            'name': 'vmware-migration', 'path': 'vmware-migration',
            'visibility': 'private', 'default_branch': 'main',
            'initialize_with_readme': False})
    pid = project['id']
    project = api.request('GET', f'/projects/{pid}')
    if 'empty_repo' not in project:
        raise ProvisionError('Missing empty_repo metadata')
    if project['empty_repo']:
        api.request('POST', f'/projects/{pid}/repository/commits', {
            'branch': 'main', 'commit_message': 'Initial platform folder',
            'actions': [{'action': 'create', 'file_path': 'platform/README.md',
                         'content': data['readme']}]})
        api.request('PUT', f'/projects/{pid}', {'default_branch': 'main'})
    elif project['default_branch'] != 'main':
        raise ProvisionError('Existing project must have main as its default branch')
    saved = data.get('flux')
    tokens = list(api.list_all(f'/projects/{pid}/deploy_tokens'))
    active = [x for x in tokens if x['name'] == 'vmware-flux' and not x.get('revoked')
              and not x.get('expired')]
    if saved:
        if not any(x['id'] == saved['id'] and x['scopes'] == ['read_repository']
                   for x in active):
            raise ProvisionError('Saved Flux token is not active; manual recovery required')
        return saved
    if active:
        raise ProvisionError('Flux token exists but its local secret is missing; restore state')
    token = api.request('POST', f'/projects/{pid}/deploy_tokens', {
        'name': 'vmware-flux', 'scopes': ['read_repository']})
    return {key: token[key] for key in ('id', 'username', 'token')}


if __name__ == '__main__':
    # The caller captures stdout directly into a private state file.
    try:
        json.dump(provision(json.load(sys.stdin)), sys.stdout)
    except Exception:
        print('GitLab provisioning failed; check existing resources and saved state.', file=sys.stderr)
        sys.exit(1)
