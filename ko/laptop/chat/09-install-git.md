## 9. git 설치하기

**마지막 도구 — 이것으로 자료를 가져옵니다**

📍 **어디서:** 여러분의 노트북에서.

먼저 이미 설치되어 있는지 확인하십시오: macOS와 대부분의 Linux 빌드에서는 git이
기본으로 설치되어 있습니다.
```
git --version
```
버전이 출력되었다면 — 이 안내는 건너뛰십시오.

**macOS.** 가장 쉬운 방법은 시스템 대화 상자에 맡기는 것입니다: `git --version`을 입력하면,
git이 설치되어 있지 않을 경우 macOS가 알아서 개발자 도구 설치를 제안합니다. 수락하십시오.
또는 명시적으로:
```bash
xcode-select --install
```
Homebrew를 쓴다면:
```bash
brew install git
```

**Linux** — 배포판 계열에 따라 다릅니다:
```bash
sudo apt-get update && sudo apt-get install -y git    # Debian, Ubuntu
sudo dnf install -y git                               # Fedora, RHEL, CentOS Stream
```

**Windows** (PowerShell):
```powershell
winget install -e --id Git.Git
```
그런 다음 PowerShell을 닫았다가 다시 여십시오. 그러지 않으면 명령을 찾지 못합니다.

⚠️ **`winget`을 찾지 못하면** — git은 일반 설치 프로그램으로도 설치됩니다: 
https://git-scm.com/download/win 을 열고, 파일을 내려받아 실행한 뒤 모든 단계에서
"다음"을 누르십시오, 바꿀 것은 없습니다. 설치가 끝나면 — 새 PowerShell 창을 여십시오.
또는 git 없이 아래의 Download ZIP 방식으로 해결하십시오.

**확인해 봅시다:**
```
git --version
```

🖱 **git을 설치하고 싶지 않다면** — 이것은 파일 폴더를 내려받기 위해 딱 한 번만
필요합니다. 브라우저로도 해결할 수 있습니다:
https://github.com/aenix-org/cozystack-migration-workshop 을 열고, 초록색
**Code → Download ZIP** 버튼을 눌러 압축을 푸십시오. 그 이후는 모두 동일하며,
`cd cozystack-migration-workshop` 대신 압축을 푼 폴더로 들어가면 됩니다.
