## 8. 클러스터에 로그인하기

**여러분의 테넌트에 접속하기**

📍 **위치:** 대시보드는 브라우저에서 열고, 명령은 여러분의 노트북에서 실행합니다.

**여러분의 접속 정보:**
```
dashboard: https://dashboard.workshop.aenix.io
login:     workshopXX      ← your number, I'll tell you in person
password:  ...             ← I'll tell you in person
```

1. 위 링크로 대시보드를 엽니다.
2. 여러분의 로그인으로 로그인합니다.
3. 대시보드에서: **Info → Secrets 탭 → `kubeconfig-tenant-workshopXX`**. *Reveal*을 클릭하고
   내용을 복사합니다.
4. 파일에 저장하고 변수가 그 파일을 가리키게 합니다:

**macOS 및 Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # 복사한 내용을 붙여넣고 저장하세요
export KUBECONFIG=~/.kube/workshop
```

**Windows** (PowerShell)
```powershell
notepad $HOME\.kube\workshop   # 붙여넣고 저장하세요
$env:KUBECONFIG = "$HOME\.kube\workshop"
```

**확인해 봅니다:**
```
kubectl get vminstance -n tenant-workshopXX
```
브라우저가 열립니다 — `workshopXX`로 로그인하세요. 그 다음 명령은 `No resources found`라고
응답해야 합니다. 이것이 올바른 응답입니다: 아직 머신은 없지만 클러스터가 여러분을 인식하고 있습니다.

⚠️ 사람들이 가장 자주 걸려 넘어지는 두 가지:
• `KUBECONFIG`는 여러분이 설정을 붙여넣은 바로 그 파일을 정확히 가리켜야 합니다.
• `kubectl get vm`과 `kubectl get vmi`는 동작하지 않습니다 — 여러분의 계정에서는 `vminstance` 타입을
  사용할 수 있습니다. 의도된 동작입니다.

⚠️ **`x509: certificate signed by unknown authority`** — 두 번째로 자주 나타나는 오류이며, 거의
언제나 Windows에서 발생합니다. 이것은 인증서에 문제가 있다는 뜻이 아니라 `kubectl`이 **잘못된
접근 파일**을 집어 들었다는 뜻입니다: 클러스터 내부 인증 기관에 대한 신뢰는 여러분의 kubeconfig 안
`certificate-authority-data` 필드에 들어 있는데, 기본 파일에는 그것이 없습니다.

PowerShell에서 단계별로 짚어 봅니다:
```powershell
$env:KUBECONFIG
# 비어 있음 — 발급받은 파일이 아니라 기본 파일을 사용하고 있다는 뜻입니다

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — 파일이 불완전하게 저장되었습니다. 대시보드에서 시크릿을 다시 다운로드하세요

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# apiVersion으로 시작해야 합니다. 작은 네모나 빈 내용이 보이면 파일이 UTF-16입니다
```

세 번째 항목은 Windows에서 가장 고약한 함정입니다. 메모장과 `>` 리디렉션은 파일을 **UTF-16**으로
저장하는데, `kubectl`은 그런 파일을 읽지 못합니다. UTF-8로만 저장하세요: 메모장에서는 파일 형식을
"모든 파일"로 선택하고, 명령줄에서는 `>`가 아니라 `Out-File -Encoding utf8`을 사용하세요.
