## 5. Installing virtctl

**virtctl — managing VMs**

⚠️ **Careful: install the version that matches the cluster, not the newest one.** A client newer than the server changes the command syntax, and half the questions at past workshops came from exactly this. Our cluster runs **v1.8.4** — that is the version pinned in every block below. Do not switch it to latest.

**macOS**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-darwin-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```
If macOS complains that it "cannot verify the developer":
```bash
sudo xattr -d com.apple.quarantine /usr/local/bin/virtctl
```

**Linux**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-linux-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```

**Windows** (PowerShell, run as an ordinary user)
```powershell
$ver = "v1.8.4"
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
After this, **close the PowerShell window and open a new one** — otherwise the updated PATH won't be picked up.

**Verify (the same everywhere):**
```
virtctl version
```
A `Client Version:` line with a number should appear. A complaint about not being able to reach the server is normal at this step — we haven't connected to it yet.

**About the machine name in commands.** With client v1.8.4 the machine is given by its bare name, with no prefix: `vm-instance-app-1`. If a newer client did end up installed and it answers `target must contain type and name separated by '/'` — add the **`vmi/`** prefix: `vmi/vm-instance-app-1`.

⚠️ The prefix is `vmi/`, not `vm/`. With `vm/` you'll get a permissions error (`cannot get resource "virtualmachines/portforward"`): the participant is granted rights to running machine instances, not to their definitions.
