## 6. kubelogin 설치

**kubelogin — 계정으로 로그인하기**

이것이 없으면 `kubectl`은 로그인을 위해 브라우저를 열 수 없고, 계속 인가 오류로만 응답합니다.
파일 이름은 반드시 정확히 `kubectl-oidc_login`이어야 합니다 — kubectl이 플러그인으로 찾는 이름이
바로 이것입니다.

**macOS**
```bash
brew install int128/kubelogin/kubelogin
```
Homebrew가 없다면:
```bash
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o kubelogin.zip "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_darwin_${ARCH}.zip"
unzip -o kubelogin.zip kubelogin
chmod +x kubelogin
sudo mv kubelogin /usr/local/bin/kubectl-oidc_login
rm kubelogin.zip
```

**Linux**
```bash
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o kubelogin.zip "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_${ARCH}.zip"
unzip -o kubelogin.zip kubelogin
chmod +x kubelogin
sudo mv kubelogin /usr/local/bin/kubectl-oidc_login
rm kubelogin.zip
```

**Windows** (PowerShell)
```powershell
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_windows_amd64.zip" -OutFile "$HOME\kubelogin.zip"
Expand-Archive -Force "$HOME\kubelogin.zip" "$HOME\kubelogin-tmp"
Move-Item -Force "$HOME\kubelogin-tmp\kubelogin.exe" "$HOME\bin\kubectl-oidc_login.exe"
Remove-Item -Recurse -Force "$HOME\kubelogin.zip","$HOME\kubelogin-tmp"
```
(`$HOME\bin` 폴더는 이전 단계에서 이미 만들어 PATH에 추가해 두었습니다)

**확인해 봅시다:**
```
kubectl oidc-login --help
```
도움말이 출력되었다면 플러그인이 제자리에 있고 kubectl이 이를 인식하는 것입니다.
