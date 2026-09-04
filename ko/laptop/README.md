# 워크숍: VMware VM을 Cozystack으로 마이그레이션하기(자신의 노트북에서)

VMware의 가상 머신에서 수년간 돌아온 애플리케이션을 Cozystack으로 옮깁니다. 전 과정을
직접 손으로 진행합니다.

> 강사가 도구와 접근이 이미 갖춰진 공유 VM(bastion(공유 VM))을 주었다면 — 다른 세트인
> [`../bastion/`](../bastion/)가 필요합니다. 거기서는 모든 것이 이미 설정되어 있습니다.

이 파일은 경로 안내입니다. 무엇 다음에 무엇이 오는지, 어떤 명령을 입력해야 하는지, 그리고
결과적으로 무엇을 얻어야 하는지를 담고 있습니다. 왜 이런 방식으로 구성했는지에 대한 설명과
매니페스트·스크립트의 한 줄 한 줄 해설은 [`chat/`](chat/) 폴더에 — 메시지 하나당 파일 하나로 —
들어 있습니다. 링크는 각 단계 끝에 있습니다.

## 경로

애플리케이션은 세 대의 머신에 걸쳐 있습니다. 애플리케이션 자체, 데이터베이스, 그리고 메시지
큐입니다. 우리는 첫 번째만 옮깁니다. 데이터베이스와 큐는 그 자리에 남고, 그 대신 Cozystack
카탈로그에서 이미 만들어진 것을 가져옵니다.

| 단계 | 하는 일 | 위치 |
|---|---|---|
| 1 | 이미지를 위한 스토리지를 준비합니다 | 노트북에서 |
| 2 | 디스크를 VMware 포맷에서 KVM 포맷으로 다시 포장합니다 | 임시 머신에서 |
| 3 | 머신을 새 보금자리에서 띄웁니다 | 노트북에서 |
| 4 | 카탈로그에서 데이터베이스와 큐를 주문합니다 | 노트북에서 |
| 5 | 네트워크를 손보고 애플리케이션을 새 주소로 전환합니다 | 여러분의 머신 안에서 |

그다음에는 마지막 확인이 이어집니다. 애플리케이션에서 만든 주문이 데이터베이스와 큐까지 온전히
도달하는지 확인합니다.

## 강사가 준 것

강사가 주는 것:

* dashboard https://dashboard.workshop.aenix.io
* 사용자 이름 `workshopXX`, 비밀번호는 현장에서 알려줍니다
* kubeconfig — dashboard에서: `Info` → `Secrets` 탭 → `kubeconfig-tenant-workshopXX` secret

아래 모든 곳에서 `workshopXX`를 자신의 번호로 바꾸세요.

## 시작하기 전에: 유틸리티 네 가지

워크숍 전에 노트북에 한 번 설치해 둡니다.

| 유틸리티 | 용도 | 설치 |
|---|---|---|
| `kubectl` | 파일을 적용하고, 클러스터에 무엇이 있는지 보여줍니다 | [chat/04](chat/04-install-kubectl.md) |
| `virtctl` | 가상 머신 콘솔과 포트 포워딩 | [chat/05](chat/05-install-virtctl.md) |
| `kubelogin` | 브라우저를 통한 로그인, 없으면 클러스터가 들여보내지 않습니다 | [chat/06](chat/06-install-kubelogin.md) |
| `git` | 이 저장소를 가져오기 위해 | [chat/09](chat/09-install-git.md) |

⚠️ **이 워크숍에는 krew가 필요 없습니다** — 이유는 [chat/07](chat/07-about-krew.md)에.

모든 것이 갖춰졌는지 확인합니다. 각 명령은 "command not found"가 아니라 버전이나 도움말을
출력합니다:

```bash
kubectl version --client
virtctl version --client
kubectl oidc-login --help
```

## 클러스터에 접속하기

dashboard에서 받은 kubeconfig를 디스크에 저장하고 `KUBECONFIG` 변수가 그것을 가리키게 합니다.

**macOS와 Linux** — secret의 내용을 `~/.kube/workshop`에 넣은 뒤:

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Windows (PowerShell):**

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
notepad "$HOME\.kube\workshop"    # kubeconfig를 붙여 넣으세요; 파일 형식 — "모든 파일"
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

첫 요청 때 브라우저가 열립니다 — `workshopXX`로 로그인하세요.

⚠️ **Windows: 파일은 반드시 UTF-8로만 저장하세요.** 메모장과 PowerShell의 `>` 리디렉션은
UTF-16으로 기록하는데, `kubectl`은 그런 파일을 읽지 못합니다 — 인증서에 아무 문제가 없어도
`x509: certificate signed by unknown authority`라고 응답합니다.

⚠️ `dial tcp [::1]:8080 ... refused` 오류는 `kubectl`이 kubeconfig를 찾지 못했다는 뜻이지,
클러스터에 닿을 수 없다는 뜻이 아닙니다. 둘 다에 대한 해설은 [chat/08](chat/08-connect-to-cluster.md)에.

## 자료 가져오기

```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/laptop
```

⚠️ `/laptop` 꼬리는 필수입니다: 이 폴더에 매니페스트와 스크립트가 담긴 노트북 경로의 자료가
들어 있습니다. 이것이 없으면 명령이 `manifests`도 `scripts`도 찾지 못합니다.

모든 파일에는 `tenant-workshopXX` 자리 표시자가 있습니다. 자신의 번호로 한꺼번에 바꾸세요
(예시에서는 — `workshop03`):

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +

# macOS — 같은 sed지만, -i 뒤에 빈 따옴표가 필요합니다
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

```powershell
# Windows
Get-ChildItem -Path manifests,scripts -File -Recurse | ForEach-Object {
  (Get-Content $_.FullName -Raw) -replace 'tenant-workshopXX','tenant-workshop03' |
    Set-Content $_.FullName -NoNewline
}
```

자리 표시자가 하나도 남지 않았는지 확인합니다:

```bash
grep -rn tenant-workshopXX manifests scripts || echo "all clean, you can continue"
```

한 곳만 명령이 일부러 건드리지 않고 남겨 둡니다: `manifests/03-app-vm.yaml`의
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` 줄입니다 — 이 링크는 두 번째 단계 이후에 얻습니다.

자세히: [chat/10](chat/10-clone-and-set-number.md) ·
파일 맵 [chat/11](chat/11-file-map.md)

---

## 1단계. 이미지를 위한 스토리지

📍 노트북에서.

다시 포장한 디스크는 플랫폼이 네트워크로 가져올 수 있는 곳에 놓여야 합니다. 우리는 bucket —
S3 인터페이스를 가진 객체 스토리지 — 를 준비합니다.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**이렇게 보여야 합니다:** `bucket.apps.cozystack.io/my-images created`, 이어서 `READY: True`.

⚠️ **타입 이름은 `bucket`이 아니라 전체를 적으세요.** 이 단어는 클러스터에서 세 번 쓰입니다:
카탈로그의 우리 타입, Flux 타입, 그리고 객체 스토리지 표준의 타입입니다. 셋 중 어느 것을
`kubectl`이 짧은 이름 대신 넣을지는 미리 알 수 없으며, 엉뚱한 것이 걸리면 요청한 적도 없는
리소스에 대해 권한 거부가 뜹니다: `buckets.source.toolkit.fluxcd.io is forbidden`. 이것은 접근
문제가 아니며, 고칠 것도 없습니다.

⚠️ **`apply`가 `SchemaError … unknown model in reference`로 실패한다면** — 걸리는 것은
클라이언트 측 검증이지 클러스터가 아닙니다. 매니페스트는 올바릅니다. 우회하려면:
`kubectl apply -f manifests/01-bucket.yaml --validate=false`. 이 플래그는 로컬 검사만 끕니다.
서버는 여전히 자기 쪽에서 객체를 검증합니다.

**다음에 키가 필요합니다:** dashboard → `Bucket` → `my-images` → `Secrets` 탭 →
`bucket-my-images-app-credentials` secret. 거기서 `bucketName`, `accessKey`, `secretKey`를
가져옵니다 — 다음 단계의 스크립트에 넣을 것입니다.

매니페스트 해설: [chat/13](chat/13-bucket-manifest.md) ·
단계 전체: [chat/14](chat/14-step-1-bucket.md)

---

## 2단계. 디스크 다시 포장하기

📍 먼저 노트북에서, 그다음 임시 머신 안에서.

VMware의 디스크는 VMDK 포맷으로 기록되어 있지만, KVM은 QCOW2를 읽습니다. `virt-v2v`가 다시
포장을 처리합니다. 한 번 쓰자고 노트북에 설치할 이유가 없으니, 도구가 이미 갖춰진 임시 머신을
띄웁니다.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**이렇게 보여야 합니다:** `created`가 붙은 두 줄, 이어서 `Running`.

⚠️ `Running`은 "켜졌다"는 뜻이지 "준비됐다"는 뜻이 아닙니다: 내부에서는 `cloudInit`이 몇 분 더
계속 작동하며 — 패키지를 설치하고 `mc`를 내려받습니다. 너무 일찍 로그인하면 `virt-v2v`를 찾지
못합니다.

로그인합니다(사용자 이름 `ubuntu`, 비밀번호 `ubuntu`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

내부에서: `nano convert.sh`로 `scripts/convert.sh`의 내용을 붙여 넣고, `ВСТАВЬТЕ_...` 자리에
자신의 `bucketName`, `accessKey`, `secretKey`를 넣은 뒤 `bash convert.sh`를 실행합니다.

**이렇게 보여야 합니다:** 출력의 끝, `Share:`라는 단어 뒤에 — 이미지로 향하는 서명된 링크가 있습니다.
다음 단계에서 필요합니다.

매니페스트 해설: [chat/15](chat/15-conversion-vm-manifest.md) ·
스크립트 해설: [chat/17](chat/17-convert-script.md) ·
두 단계 전체: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## 3단계. 새 보금자리의 머신

📍 노트북에서.

⚠️ 먼저 변환용 머신을 끄세요 — 할 일을 마쳤고 여러분 쿼터의 8Gi를 붙잡고 있습니다. 없애지
않으면 새 머신이 `Pending`에 걸린 채 멈춰 있게 됩니다:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

받은 링크를 `manifests/03-app-vm.yaml`의 `url: "ВСТАВЬТЕ_PRESIGNED_URL"` 자리에 넣은 뒤:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**이렇게 보여야 합니다:** `created`가 붙은 두 줄, 이어서 `Running`. 여기서는 기다림이 더 깁니다 —
플랫폼이 여러분의 링크에서 이미지를 내려받고 있습니다.

로그인합니다(사용자 이름 `root`, 비밀번호 `cozydemo`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **내부에는 네트워크가 없습니다.** 이것은 고장 난 테스트베드가 아니라 원래 그래야 하는
모습입니다. 5단계에서 고칩니다.

매니페스트 해설: [chat/20](chat/20-app-vm-manifest.md) ·
단계 전체: [chat/21](chat/21-step-4-your-vm.md)

---

## 4단계. 카탈로그에서 가져오는 데이터베이스와 큐

📍 노트북에서.

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**이렇게 보여야 합니다:** `postgres.apps.cozystack.io/db created`와
`kafka.apps.cozystack.io/kafka created`. Kafka는 Postgres보다 눈에 띄게 더 오래 올라옵니다.

매니페스트 해설: [chat/23](chat/23-managed-manifest.md) ·
단계 전체: [chat/24](chat/24-step-5-database-and-queue.md)

---

## 5단계. 애플리케이션 연결하기

📍 여러분의 가상 머신 안에서.

엄격한 순서로 세 가지 작업을 합니다: 네트워크가 없으면 스크립트가 데이터베이스에 닿을 수 없고,
데이터베이스가 없으면 스키마를 받아들이지 못합니다.

| 단계 | 무엇을 고치나 | 무엇으로 |
|---|---|---|
| 5.1 | 머신에 네트워크가 없다 | `scripts/netfix-dhcp.sh` |
| 5.2 | 애플리케이션이 옛 주소를 찾는다 | `scripts/connect-managed.sh` |
| 5.3 | 새 데이터베이스에 테이블이 없다 | `scripts/orders-schema.sql` |

**5.1.** 이 스크립트는 `BOOTPROTO=static`을 `dhcp`로 바꾸고 VMware 네트워크의 주소를 제거합니다.
직접 손으로 입력합니다 — 머신에 아직 네트워크가 없어서 파일을 내려받을 수 없기 때문입니다.
그다음 머신을 **재부팅**해야 합니다: CentOS 7은 부팅 시에 네트워크 설정을 적용합니다.

**5.2.** 이 스크립트는 `/etc/orders/application.properties`에 하드코딩된 주소 `192.168.10.30`과
`192.168.10.40`을 서비스 이름으로 바꾸고 애플리케이션을 재시작합니다.

**5.3.** `psql` 클라이언트를 설치하고 스키마를 적용합니다 — 명령은 아래 마지막 확인에 있습니다.

자세히: [chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## 마지막 확인: 순서대로 세 단계

### 1단계. firewalld 끄기

📍 여러분의 머신 안에서. 옛 네트워크에서 남은 규칙들이 애플리케이션으로 가는 요청을 끊고 있습니다.

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**이렇게 보여야 합니다:** `200`. `503`이면 — 데이터베이스나 큐에서 무언가가 연결되지 않은 것입니다.

### 2단계. 데이터베이스 스키마

📍 여러분의 머신 안에서. CentOS 7의 기본 psql은 버전 9.2입니다; SCRAM을 처리하지 못하고
`SCRAM authentication requires libpq version 10 or above`라고 응답합니다. 새 것을 설치합니다:

```bash
# 1. PGDG 저장소 — PostgreSQL 패키지의 출처
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd: CentOS 7 저장소에 없으므로 EPEL 아카이브에서 가져옵니다
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. 클라이언트 본체 — 살아 있는 pgdg15 저장소에서만
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ 두 번째와 세 번째 명령은 군더더기가 아닙니다. `libzstd`가 없으면 설치가
`Requires: libzstd >= 1.4.0`에서 실패합니다. `--disablerepo`/`--enablerepo`가 없으면 —
`HTTPS Error 410 - Gone`에서 실패합니다: 저장소 패키지는 수명이 끝난 12와 13을 포함해 모든
PostgreSQL 버전을 한꺼번에 활성화하며, 설치 전에 `yum`은 활성화된 모든 저장소를 훑다가 첫 번째
죽은 저장소에서 실패합니다.

```bash
psql --version
```

`command not found`가 뜨면 — 클라이언트가 `PATH` 밖에 설치된 것입니다: `ls /usr/pgsql-*/bin/psql`를
살펴본 뒤 `export PATH="$PATH:/usr/pgsql-15/bin"`.

스키마를 가져와서 적용합니다:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**이렇게 보여야 합니다:** 마지막 명령에서 — `orders` 테이블.

데이터베이스 주소는 IP가 아니라 이름입니다: `postgres-db-rw`(`db` 서비스, 읽기-쓰기),
`tenant-workshopXX`(여러분의 namespace), `svc.cozy.local`(클러스터 내부 이름의 접미사).
비밀번호는 `manifests/04-managed.yaml`에 설정되어 있으니, 어디선가 뒤질 필요가 없습니다.

자세히: [chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### 3단계. 포트 포워딩과 바깥에서 확인하기

📍 노트북에서.

```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

창을 닫지 마세요 — 터널은 명령이 실행되는 동안만 살아 있습니다. 다른 창에서:

```bash
curl -s http://localhost:8080/actuator/health

curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s http://localhost:8080/api/orders
```

**이렇게 보여야 합니다:** 목록에 그 주문이 있습니다. 여정 전체가 완료되었습니다.

자세히: [chat/30](chat/30-step-9-verify-chain.md)

---

## 치트 시트

> **`vmi/` 접두사가 모든 명령에 필요한 것은 아니며, 이것은 오타가 아닙니다.** 두 명령은 대상
> 문법이 다릅니다. `virtctl console`은 이름만 받으며, 접두사를 붙이면 `vmi`라는 단어를 머신
> 이름으로 여겨 `forbidden`이라고 응답합니다. `virtctl port-forward`는 `type/name`을 요구하며,
> 접두사가 없으면 `target must contain type and name separated by '/'`라고 응답합니다.

```bash
# app-VM에 로그인 (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# conversion-VM에 로그인 (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# 애플리케이션의 포트를 노트북으로 포워딩
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

콘솔에서 나가려면 — `Ctrl+]`. 접속한 뒤 화면이 비어 있으면 Enter를 누르세요. 같은 것을 마우스로도
할 수 있습니다: dashboard의 머신 페이지에 있는 **VNC** 버튼입니다.

## 막히기 쉬운 곳

* conversion-VM에는 `ubuntu-20.04`만 쓰세요. 24.04에서는 커널이 패닉을 일으키고, 22.04에서는
  `virt-v2v`가 오래된 CentOS 7 RPM 데이터베이스를 파싱하지 못합니다.
* 카탈로그 이미지용 VMDisk는 이미지 자체보다 커야 합니다. 그렇지 않으면 클론이 통과되지 못하고
  디스크가 `Terminating`에 걸립니다. `ubuntu-20.04`에는 25Gi면 충분합니다.
* 새 app-VM에서는 먼저 `netfix`, 그다음 `connect` — 그렇지 않으면 애플리케이션이 매니지드
  서비스를 보지 못합니다.
* `.yaml` 파일을 Word나 Google Docs에서 열지 마세요: 따옴표와 대시가 바뀌어 파일이 더 이상
  적용되지 않고, 오류는 영문을 알 수 없어 보입니다.

나머지 함정들은 — [chat/31](chat/31-troubleshooting.md).

## 테스트베드를 준비하는 분들께

쿼터, 테넌트 생성 순서, 플랫폼 버전은 — [REQUIREMENTS.md](../REQUIREMENTS.md)에 있습니다.

## 모든 메시지를 순서대로

32개 메시지 목록은 — [chat/README.md](chat/README.md).
