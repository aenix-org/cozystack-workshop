## 29. 8단계: 클라이언트 설치 및 스키마 적용

**데이터베이스 접속 정보:**
```
host:     postgres-db-rw.tenant-workshopXX.svc.cozy.local
database: orders
login:    orders
password: Orders2019!
```
비밀번호는 `manifests/04-managed.yaml`에 설정되어 있으니, 다른 곳에서 찾을 필요가 없습니다.

⚠️ **CentOS 7에 기본 포함된 psql로는 안 됩니다.** 버전이 9.2인데, 우리 데이터베이스는
SCRAM 인증을 요구하고 이 버전은 그걸 처리하지 못해서 다음과 같이 응답합니다:
`psql: SCRAM authentication requires libpq version 10 or above`. 버전 10 이상의 클라이언트가 필요합니다.
PGDG 저장소에서 가져오는데, CentOS 7에서 그곳에 있는 최신 버전은 15입니다.

명령 세 개를 연달아 실행하며, 각각에는 이유가 하나씩 있습니다:

```bash
# 1. PGDG 저장소 연결 — PostgreSQL 패키지의 출처입니다.
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd 라이브러리. 이게 없으면 클라이언트가 설치되지 않습니다. CentOS 7
#    저장소에는 없으므로, EPEL 아카이브에서 가져옵니다.
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. 클라이언트 본체 — 오직 살아 있는 pgdg15 저장소에서만.
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

두 번째와 세 번째 명령은 불필요해 보이지만, 이것들이 없으면 설치가 실패하며, 그렇지 않으면
두 오류를 직접 눈으로 보게 됩니다:

- `libzstd`가 없으면 — `Requires: libzstd >= 1.4.0`;
- `--disablerepo`/`--enablerepo`가 없으면 — `HTTPS Error 410 - Gone`. 저장소 패키지는
  수명이 끝난 12, 13 버전을 포함해 모든 PostgreSQL 버전을 한꺼번에 끌어옵니다. 그리고
  설치 전에 `yum`은 활성화된 **모든** 저장소를 훑어보다가 처음 만나는 죽은 저장소에서 실패합니다.
  그래서 우리는 필요한 것 하나만 명시적으로 남겨 둡니다.

클라이언트가 제자리에 있는지 확인합니다:

```bash
psql --version
```

응답이 `command not found`라면, 클라이언트가 `PATH` 밖에 설치된 것입니다. 위치를 찾아
현재 세션에 해당 디렉터리를 추가하세요:

```bash
ls /usr/pgsql-*/bin/psql
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**스키마 파일을 가져옵니다** — 이 머신에는 이미 네트워크가 있습니다:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql
```

**적용합니다.** 무턱대고 입력하지 않도록, 명령을 부분별로 뜯어봅시다:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -f orders-schema.sql
```

- `PGPASSWORD='...'` — 비밀번호를 환경 변수로 전달하여, `psql`이 대화형으로 비밀번호를
  묻지 않게 합니다. 스크립트에서는 이렇게 합니다.
- `-h postgres-db-rw.tenant-workshopXX.svc.cozy.local` — 데이터베이스 주소. 이것은 **IP가 아니라**
  클러스터 내부 이름입니다. `-rw` 접미사가 중요합니다: managed Postgres에는 여러 개의
  복제본이 있는데, 이 이름은 항상 **쓰기가 가능한** 복제본을 가리킵니다. `-ro`가 붙은 짝
  이름도 있는데 — 읽기 전용입니다. 복제본 사이에서 역할이 전환되어도 이름은 바뀌지 않으며,
  그래서 애플리케이션 설정에는 특정 서버의 주소가 아니라 이 이름을 적어 둡니다.
- `-U orders` — 어떤 사용자로 접속할지, `-d orders` — 어떤 데이터베이스에 접속할지.
- `-f orders-schema.sql` — 파일에 담긴 명령들을 실행합니다.

IP가 아니라 변하지 않는 이름으로 데이터베이스에 접근할 수 있다는 바로 그 점이, 복제본 전환을
애플리케이션에게 보이지 않게 만듭니다. 예전 머신에서는 설정에 `localhost`가 적혀 있었고,
애초에 전환이라는 것 자체가 없었습니다.

테이블이 제자리에 있는지 확인합니다:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -c '\dt'
```

나타났다면 — 이제 주문이 생성될 것입니다. 다음 단계에서 전체 체인과 함께 이를 확인하겠습니다.
