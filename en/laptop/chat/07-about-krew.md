## 7. About krew — and why we don't use it

**Short answer: don't install it today**

krew is a plugin manager for kubectl, and you can use it to install those same virtctl and kubelogin.
But at past workshops it's exactly krew that ate up the most time, especially on Windows.
If you've done steps 3 and 4 — **you already have everything, skip this post**.

Read on only if you already have krew installed or really want it.

⚠️ **Three Windows pitfalls, all seen in the wild:**
• **PATH didn't refresh in the current window.** The most common one. Fix it right in the same session:
  `$env:Path += ";$HOME\.krew\bin"`
• **krew.exe didn't finish installing** — SmartScreen or antivirus killed it. Check:
  `Test-Path "$HOME\.krew\bin\kubectl-krew.exe"`
• **An admin PowerShell window and a regular one are different worlds.** They have different `$HOME`
  and a different user PATH. Install it as administrator, run it as a regular user —
  and the plugin will never be found. Install and run in one and the same regular window.

**macOS and Linux** — copy the whole block, it detects the system on its own:
```bash
set -x; cd "$(mktemp -d)" &&
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64$/arm64/')" &&
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-${OS}_${ARCH}.tar.gz" &&
tar zxvf "krew-${OS}_${ARCH}.tar.gz" &&
./"krew-${OS}_${ARCH}" install krew
```
Then add krew to your PATH — you need to append the line to your profile, otherwise it will be forgotten
the next time you start the terminal:
```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc   # for zsh, the default on macOS
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc  # for bash, usually Linux
source ~/.zshrc    # or source ~/.bashrc
```

**Windows** (PowerShell)
```powershell
Invoke-WebRequest -Uri "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.exe" -OutFile "$HOME\krew.exe"
& "$HOME\krew.exe" install krew
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\.krew\bin", "User")
Remove-Item "$HOME\krew.exe"
```
Close and reopen PowerShell again.

**Installing the plugins:**
```bash
kubectl krew install virt
kubectl krew install oidc-login
```

⚠️ An important difference: when installed via krew the command is named differently —
`kubectl virt console …` instead of `virtctl console …`. Further on in the instructions I write
`virtctl` — if you installed via krew, mentally substitute `kubectl virt`.
To avoid confusion, you can set up a short alias:
```bash
alias virtctl="kubectl virt"
```
