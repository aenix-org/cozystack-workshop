"""GitLab API transport copied from fraud-workshop/v2/gitlab/provision.py."""
import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

class ProvisionError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Do not forward the administrator credential to a redirected host.
        return None


class GitLab:
    def __init__(self, url, token):
        self.base = url.rstrip('/') + '/api/v4'
        self.token = token
        self.opener = build_opener(NoRedirect())

    def request(self, method, path, data=None, missing_ok=False):
        request = Request(
            self.base + path,
            data=json.dumps(data).encode('utf-8') if data is not None else None,
            headers={'PRIVATE-TOKEN': self.token, 'Content-Type': 'application/json'},
            method=method,
        )
        try:
            with self.opener.open(request, timeout=60) as response:
                body = response.read()
                return json.loads(body) if body else None
        except HTTPError as exc:
            if missing_ok and exc.code == 404:
                return None
            # GitLab errors may echo supplied data; redact all supplied secrets.
            detail = exc.read().decode('utf-8', errors='replace')
            for secret in (self.token, (data or {}).get('password')):
                if secret:
                    detail = detail.replace(secret, '[REDACTED]')
            raise ProvisionError(
                f'{method} {path}: HTTP {exc.code}: {detail[:1000]}'
            ) from None
        except (URLError, TimeoutError, OSError) as exc:
            raise ProvisionError(f'{method} {path}: connection failed: {exc}') from None
        except ValueError:
            raise ProvisionError(f'{method} {path}: invalid JSON response') from None

    def list_all(self, path, **query):
        page = 1
        while True:
            rows = self.request('GET', path + '?' + urlencode(
                dict(query, per_page=100, page=page)))
            if not isinstance(rows, list):
                raise ProvisionError(f'GET {path}: expected a list')
            yield from rows
            if len(rows) < 100:
                return
            page += 1


