## 8. bastion(공유 VM)에 로그인하기

**한 번의 로그인으로 이미 클러스터 안에 있습니다**

📍 **위치:** 대시보드는 브라우저에서 열고, 나머지는 모두 bastion에서 SSH로 진행합니다.

**여러분의 접속 정보** (로그인과 비밀번호는 세 곳 모두 동일합니다):
```
dashboard: https://dashboard.workshop.aenix.io
bastion:   ssh workshopXX@<bastion-주소>
login:     workshopXX      ← 여러분의 번호, 직접 알려드립니다
password:  ...             ← 직접 알려드립니다
```

bastion에 로그인합니다 — 비밀번호는 대시보드와 동일하며, **SSH 키는 필요하지 않습니다**:

```bash
ssh workshopXX@<bastion-주소>
```

접속하면 클러스터 접근이 이미 설정되어 있습니다: kubeconfig는 `~/.kube/config`에 있고, `kubectl`은
여러분의 테넌트를 곧바로 인식합니다. **이때 브라우저는 열리지 않습니다** — 클러스터 로그인은 Keycloak
없이 토큰으로 이루어집니다. 확인해 봅니다:

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

첫 번째 명령은 `tenant-workshopXX`를 보여주고, 두 번째 명령은 `No resources found`라고 응답합니다.
이것이 올바른 응답입니다: 아직 머신은 없지만 클러스터가 여러분을 인식하고 있습니다.

⚠️ `kubectl get vm`과 `kubectl get vmi`는 동작하지 않습니다 — 여러분의 계정에서는 `vminstance` 타입을
사용할 수 있습니다. 의도된 동작입니다.

⚠️ 브라우저의 대시보드(마우스로 진행하는 시각적 단계용)는 동일한 로그인과 비밀번호를 사용합니다. 하지만
대시보드에서 받는 kubeconfig(`Info → Secrets → kubeconfig-tenant-workshopXX`)는 bastion에 다운로드할
**필요가 없습니다**: 그것은 브라우저를 통한 로그인을 위한 것이고, bastion에는 그것 없이도 동작하는 준비된
kubeconfig가 이미 있습니다.
