#!/bin/bash
# Invoked with sudo; receives a private JSON payload through stdin.
set +x
set -euo pipefail
umask 077
for tool in kubectl virtctl git python3; do command -v "$tool" >/dev/null; done
python3 -c '
import json, os, pathlib, pwd, subprocess, sys
from urllib.parse import quote
d=json.load(sys.stdin); u=d["login"]
def run(*args, **kw):
    return subprocess.run(args, check=True, **kw)
try:
    account=pwd.getpwnam(u)
except KeyError:
    run("useradd", "-m", "-s", "/bin/bash", u)
    run("chpasswd", input=u+":"+d["password"]+"\n", text=True)
    account=pwd.getpwnam(u)
h=pathlib.Path(account.pw_dir)
def private(path, value):
    if path.is_symlink(): raise RuntimeError("Refusing symlink")
    if not path.exists():
        fd=os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
        with os.fdopen(fd,"w") as f: f.write(value)
    elif path.read_text() != value:
        raise RuntimeError("Existing credential file differs from saved state")
    os.chmod(path,0o600); os.chown(path,account.pw_uid,account.pw_gid)
os.chmod(h,0o750)
k=h/".kube"; k.mkdir(mode=0o700,exist_ok=True)
os.chown(k,account.pw_uid,account.pw_gid)
private(k/"config",json.dumps(d["kubeconfig"],indent=2)+"\n")
private(h/".git-credentials","https://"+quote(u,safe="")+":"+quote(d["password"],safe="")+"@gitlab.workshop.aenix.io\n")
private(h/"credentials.txt",d["handout"])
def user(*args): run("sudo","-H","-u",u,*args)
for key,value in (("user.name",u),("user.email",u+"@workshop.aenix.io"),("credential.helper","store"),("init.defaultBranch","main")):
    user("git","config","--global",key,value)
repo=h/"vmware-migration"
if not repo.exists(): user("git","clone","https://gitlab.workshop.aenix.io/"+u+"/vmware-migration.git",str(repo))
source=h/".cozystack-workshop"
if not source.exists():
    user("git","clone","--depth","1","--branch",d.get("ref","master"),"https://github.com/aenix-org/cozystack-workshop.git",str(source))
materials=source/"en"/"bastion"
if not materials.is_dir(): raise RuntimeError("Missing en/bastion materials")
workshop=h/"workshop"
if not os.path.lexists(workshop):
    user("ln","-s",str(materials),str(workshop))
# Materials are for reading; never pull, rewrite, or remove an existing clone.
'
