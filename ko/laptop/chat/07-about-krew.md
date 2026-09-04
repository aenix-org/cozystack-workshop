## 7. krew에 대하여 — 그리고 왜 우리는 쓰지 않는가

**짧은 답: 오늘은 설치하지 마세요**

krew는 kubectl용 플러그인 관리자이며, 이것으로 앞서 말한 virtctl과 kubelogin을 설치할 수도 있습니다.
하지만 지난 워크숍들에서 시간을 가장 많이 잡아먹은 것이 바로 krew였습니다, 특히 Windows에서요.
3단계와 4단계를 마쳤다면 — **이미 필요한 것이 다 있으니, 이 글은 건너뛰세요**.

krew가 이미 설치되어 있거나 정말로 쓰고 싶은 경우에만 계속 읽으세요.

⚠️ **Windows에서의 세 가지 함정, 모두 실제로 겪은 것들입니다:**
• **현재 창에서 PATH가 갱신되지 않았습니다.** 가장 흔한 경우입니다. 바로 그 세션에서 고칠 수 있습니다:
  `$env:Path += ";$HOME\.krew\bin"`
• **krew.exe 설치가 끝까지 완료되지 않았습니다** — SmartScreen이나 백신이 그것을 죽였습니다. 확인:
  `Test-Path "$HOME\.krew\bin\kubectl-krew.exe"`
• **관리자 PowerShell 창과 일반 창은 서로 다른 세계입니다.** 둘은 `$HOME`이 다르고
  사용자 PATH도 다릅니다. 관리자로 설치하고 일반 사용자로 실행하면 —
  플러그인은 영영 찾을 수 없습니다. 같은 일반 창에서 설치하고 실행하세요.

**macOS와 Linux** — 블록을 통째로 복사하세요, 시스템을 알아서 판별합니다:
```bash
set -x; cd "$(mktemp -d)" &&
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64$/arm64/')" &&
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-${OS}_${ARCH}.tar.gz" &&
tar zxvf "krew-${OS}_${ARCH}.tar.gz" &&
./"krew-${OS}_${ARCH}" install krew
```
그다음 krew를 PATH에 추가하세요 — 이 줄을 자신의 프로필에 덧붙여야 합니다, 그러지 않으면
다음번에 터미널을 켤 때 잊혀집니다:
```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc   # zsh용, macOS의 기본값
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc  # bash용, 보통 Linux
source ~/.zshrc    # 또는 source ~/.bashrc
```

**Windows** (PowerShell)
```powershell
Invoke-WebRequest -Uri "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.exe" -OutFile "$HOME\krew.exe"
& "$HOME\krew.exe" install krew
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\.krew\bin", "User")
Remove-Item "$HOME\krew.exe"
```
PowerShell을 다시 닫았다가 여세요.

**플러그인 설치:**
```bash
kubectl krew install virt
kubectl krew install oidc-login
```

⚠️ 중요한 차이: krew로 설치하면 명령 이름이 달라집니다 —
`virtctl console …`이 아니라 `kubectl virt console …`입니다. 이후 안내에서는 제가
`virtctl`이라고 쓰는데 — krew로 설치했다면 머릿속으로 `kubectl virt`로 바꿔 넣으세요.
헷갈리지 않도록 짧은 별칭을 만들어 둘 수도 있습니다:
```bash
alias virtctl="kubectl virt"
```
