#!/usr/bin/env python3
"""Keycloak admin API helper for the Cozystack workshop cluster.

Token lifetime is short, so we fetch a fresh one lazily and refresh on 401.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

KUBECONFIG = os.path.expanduser("~/workshop.txt")
KCTX = "admin@workshop"
KCHOST = "https://keycloak.workshop.aenix.io"
REALM = "cozy"


def _kubectl(*args):
    env = dict(os.environ, KUBECONFIG=KUBECONFIG)
    out = subprocess.run(
        ["kubectl", "--kubeconfig", KUBECONFIG, "--context", KCTX, "--request-timeout=60s", *args],
        capture_output=True, text=True, env=env, check=True,
    )
    return out.stdout.strip()


def _admin_creds():
    import base64
    u = _kubectl("get", "secret", "keycloak-credentials", "-n", "cozy-keycloak",
                 "-o", "jsonpath={.data.username}")
    p = _kubectl("get", "secret", "keycloak-credentials", "-n", "cozy-keycloak",
                 "-o", "jsonpath={.data.password}")
    return base64.b64decode(u).decode(), base64.b64decode(p).decode()


_token = None


def token(force=False):
    global _token
    if _token and not force:
        return _token
    user, password = _admin_creds()
    data = urllib.parse.urlencode({
        "client_id": "admin-cli", "username": user,
        "password": password, "grant_type": "password",
    }).encode()
    req = urllib.request.Request(
        f"{KCHOST}/realms/master/protocol/openid-connect/token", data=data)
    with urllib.request.urlopen(req, timeout=30) as r:
        _token = json.load(r)["access_token"]
    return _token


def api(method, path, body=None, _retry=True):
    """Call the admin API. Returns (status, parsed_body_or_text)."""
    url = f"{KCHOST}/admin/realms/{REALM}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            try:
                return r.status, json.loads(raw) if raw else None
            except json.JSONDecodeError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        if e.code == 401 and _retry:
            token(force=True)
            return api(method, path, body, _retry=False)
        return e.code, e.read().decode()


