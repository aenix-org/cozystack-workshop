## 5. virtctl 설치

**virtctl — 가상 머신 관리**

⚠️ **주의: 최신 버전이 아니라 클러스터에 맞는 버전을 설치하십시오.** 서버보다 새로운 클라이언트는 명령 구문을 바꾸며, 지난 워크숍에서 나온 질문의 절반이 바로 이 때문이었습니다. 우리 클러스터는 **v1.8.4**를 사용합니다 — 아래 모든 블록에 고정된 것이 그 버전입니다. latest로 바꾸지 마십시오.

**macOS**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-darwin-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```
macOS가 "개발자를 확인할 수 없습니다"라고 알린다면:
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

**Windows** (PowerShell, 일반 사용자로 실행)
```powershell
$ver = "v1.8.4"
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
이후 **PowerShell 창을 닫고 새 창을 여십시오** — 그러지 않으면 갱신된 PATH가 적용되지 않습니다.

**확인 (어디서나 동일):**
```
virtctl version
```
`Client Version:` 줄에 번호가 함께 나타나야 합니다. 이 단계에서 서버에 연결할 수 없다는 불평이 나오는 것은 정상입니다 — 아직 서버에 연결하지 않았기 때문입니다.

**명령에서 머신 이름에 관하여.** 클라이언트 v1.8.4에서는 머신을 접두사 없이 그냥 이름으로 지정합니다: `vm-instance-app-1`. 혹시 더 새로운 클라이언트가 설치되어 `target must contain type and name separated by '/'`라고 응답한다면 — **`vmi/`** 접두사를 붙이십시오: `vmi/vm-instance-app-1`.

⚠️ 접두사는 `vm/`가 아니라 정확히 `vmi/`입니다. `vm/`를 쓰면 권한 거부(`cannot get resource "virtualmachines/portforward"`)가 돌아옵니다: 참가자에게는 실행 중인 머신 인스턴스에 대한 권한이 부여되었지, 그 정의에 대한 권한이 부여된 것이 아닙니다.
