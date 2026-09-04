# 랩 13 · Cozystack 카탈로그에 올리는 나만의 애플리케이션

| | |
|---|---|
| **소요 시간** | 40분 |
| **무엇을 증명하는가** | 플랫폼 카탈로그는 열려 있습니다. 나만의 애플리케이션이 Redis나 VM 바로 옆에 자리를 잡습니다 |
| **필요한 것** | bastion(공유 VM) 위의 `helm`, `kubectl`, 테넌트 접근 권한. 여기서는 `lab` 클러스터가 필요 없습니다 |

## 왜 중요한가

「게스트 패스(Guest Pass)」가 가동되기 시작했습니다. 일주일 뒤 자회사에서 그 소식을 듣게 됩니다. 그쪽도
같은 접수처와 같은 문제를 안고 있습니다. 다시 일주일 뒤에는 두 번째 자회사가 연락해 옵니다.

앞의 두 곳에는 말로 설명했습니다. 어떤 이미지를 쓰는지, 어떤 설정인지, 어떤 파라미터인지, 무엇을 먼저
띄워야 하는지. 세 번째쯤 되자 이래서는 안 되겠다는 것이 분명해졌습니다. 설명은 한 사람의 머릿속에만
들어 있고, 그런 머리는 하나뿐인데, 회사는 다섯 곳이 될 것입니다.

여러분에게 필요한 것은 「게스트 패스」가 그들에게도 Redis처럼 나타나는 것입니다. 카탈로그의 한 항목,
파라미터가 있는 폼, 버튼. 여러분 없이도 말입니다.

이것이 워크숍의 피날레입니다. 우리는 「Pod 하나 배포해 줘」에서 「우리 서비스가 안에 들어 있는 플랫폼,
여기 있습니다」까지의 길을 걸어왔습니다.

## 먼저 짚고 넘어갈 것: 여러분의 권한은 어디에서 끝나는가

이 랩에서는 애플리케이션을 카탈로그에 배포하지 **않습니다**. 그리고 이것은 그 부분을 작성할 시간이
모자라서가 아닙니다.

애플리케이션을 카탈로그에 등록하는 객체인 `ApplicationDefinition`은 **cluster-scoped**입니다. 클러스터당
하나이고, namespace가 없으며, 모든 테넌트의 카탈로그를 한꺼번에 바꿉니다. 테넌트는 이런 객체를 만들 수
없습니다. 지금 당장 직접 확인해 보십시오. 아무것도 만들지 않고도 자신의 권한을 클러스터에 물어볼 수
있습니다.

```bash
# KUBECONFIG — kubectl이 클러스터 주소와 로그인 정보를 읽어 오는 변수입니다.
# 여기서는 테넌트 접근 권한이며, 다른 모든 랩에서 쓰던 것과 같은 파일입니다.
export KUBECONFIG=~/.kube/config
# auth can-i = "나에게 이게 허용됩니까?". 클러스터는 yes 또는 no로 답하고 아무것도 바꾸지 않습니다:
#   create                   어떤 동작을 확인하는지
#   applicationdefinitions   어떤 유형의 객체에 대해
kubectl auth can-i create applicationdefinitions
```

**여러분이 보게 될 것:**

```
no
```

여기에 우회로는 없으며, 있어서도 안 됩니다. 그래서 이 랩은 정직하게 구성되어 있습니다. **여러분은 차트와
애플리케이션 정의를 작성하고, 로컬에서 검증한 뒤, 플랫폼 관리자에게 넘깁니다.** 실제로도 정확히 이렇게
동작합니다. 카탈로그를 만드는 일과 운영하는 일은 서로 다른 역할입니다.

익숙한 세계에서 비유하자면: OVF 템플릿의 내용은 여러분이 준비하지만, 그것을 공용 Content Library에
넣는 것은 그 라이브러리에 대한 권한을 가진 사람입니다.

## 작은 용어집

| 용어 | 무엇인가 | 비슷하지만… |
|---|---|---|
| **Helm** | 파라미터와 버전을 갖춘 매니페스트 템플릿 도구 | 입력 필드가 있는 OVF 템플릿에 가장 가깝지만, 텍스트이고 Git 안에 있습니다 |
| **차트(chart)** | Helm 패키지: 템플릿, 기본값, 스키마 | **OVF 템플릿**이지만, 한 곳에서 서로 다른 파라미터로 여러 번 배포됩니다 |
| **릴리스(release)** | 차트를 고유한 이름으로 한 번 구체적으로 배포한 것 | **템플릿에서 배포된 VM**이지만, 자신의 버전 이력을 기억하고 롤백할 수 있습니다 |
| **values** | 차트를 배포할 때 쓰는 파라미터 | **OVF 배포 마법사의 필드**이지만, 순수한 YAML이며 나머지와 함께 Git에 들어 있습니다 |
| **values.schema.json** | 허용되는 값에 대한 설명 | **마법사의 필드 검증**이지만, 적용하는 도중이 아니라 적용하기 전에 검사합니다 |
| **ApplicationDefinition** | 플랫폼 카탈로그의 한 항목: 무엇을 보여주고 무엇을 배포할지 | **Content Library의 한 항목**이지만, 클러스터당 하나이고 모든 테넌트에게 보입니다 |
| **Namespace** | 한 소유자의 객체가 사는 클러스터의 구획 | **폴더나 리소스 풀**이지만, 그 경계를 따라 권한의 경계가 지나갑니다. 여러분의 테넌트가 곧 하나의 namespace입니다 |
| **Cluster-scoped** | namespace가 없고 클러스터 전체에서 공유되는 객체 | **vCenter 수준의 설정**이지만, 그에 대한 권한은 테넌트가 아니라 플랫폼 팀에 있습니다 |
| **CRD** | Kubernetes에 새로운 유형의 객체를 추가하는 방법 | 일단 등록되면 여러분의 유형은 내장 유형과 구별되지 않습니다 |

## 랩 폴더에 무엇이 들어 있는가

모든 파일은 이미 준비되어 있습니다. 저장소와 함께 받으셨습니다. 다시 만들거나 타이핑할 것은 없습니다.
아래에서 `kubectl apply -f name.yaml`이라고 쓰여 있는 곳이면, 그 파일은 여기서 가져옵니다.

```bash
cd labs/13-catalog
```

| 파일 | 무엇인가 | 언제 쓸모가 있는가 |
|---|---|---|
| `chart/` | 카탈로그용으로 패키징된 여러분의 애플리케이션: 템플릿, values, 폼 필드 스키마 | 로컬에서 읽고 검증합니다 |
| `applicationdefinition.yaml` | 카탈로그 항목에 대한 설명: 무엇이라 부르고 대시보드에 무엇을 보여줄지 | 권한 거부를 보기 위해 적용을 시도합니다 |
| `guestpass-example.yaml` | 게시된 뒤 여러분의 애플리케이션 주문이 어떻게 보일지 | 읽습니다. 적용은 게시 이후에만 가능합니다 |
| `icon.svg`, `icon.b64` | 항목의 아이콘 — 원본과 그것을 문자열로 만든 것. 이미 정의에 포함되어 있습니다 | 아이콘을 바꿀 일이 있으면 쓸모가 있습니다 |
| `check.sh` | 차트가 렌더링되고 클러스터가 받아들이는지에 대한 점검 | 랩 마지막에 실행합니다 |

## 1단계. 우리가 무엇을 패키징하는지 살펴보기

`chart/` 폴더에는 완성된 「게스트 패스」 차트가 들어 있습니다. 안의 애플리케이션은 의도적으로 단순합니다.
페이지 하나가 있는 nginx입니다. 이 랩은 애플리케이션이 아니라 패키징에 관한 것이기 때문입니다.

```
chart/
├── Chart.yaml            이름, 버전, 설명
├── values.yaml           파라미터와 기본값
├── values.schema.json    어떤 값을 유효하다고 볼지
└── templates/
    ├── configmap.yaml    페이지와 nginx 설정
    ├── deployment.yaml   애플리케이션 자체
    └── service.yaml      주소
```

<details>
<summary><b>더 자세히: 차트 안에 무엇이 있는가</b></summary>

### `Chart.yaml` — 여권

```yaml
name: guest-pass
version: 0.1.0
appVersion: "1.0"
```

버전 번호가 두 개인데, 늘 헷갈립니다.

`version`은 **차트**의 버전, 즉 패키징의 버전입니다. 템플릿을 손보거나, 파라미터를 추가하거나, 설명의
오타를 고쳤다면 — 올립니다.

`appVersion`은 안에 든 **애플리케이션**의 버전입니다. 「게스트 패스」 자체의 새 버전이 나올 때 바뀌며,
패키징 버전과는 아무 관련이 없습니다.

실용적인 요점: `version`으로 관리자는 배포 메커니즘 자체가 갱신되는지 알 수 있고, `appVersion`으로는
사람들이 실제로 사용하는 것이 갱신되는지 알 수 있습니다.

### `values.yaml` — 파라미터

```yaml
## @param {int} replicas=2 - Number of application replicas.
replicas: 2

## @param {string} greeting=Order a pass for your guest - Text shown on the main page.
greeting: "Order a pass for your guest"

## @param {bool} external=false - Enable external access from outside the cluster.
external: false
```

`## @param` 주석은 장식도 아니고 사람을 위한 문서도 아닙니다. 이것을 바탕으로 Cozystack 생성기
(`cozyvalues-gen`)가 `values.schema.json`과 차트 README의 파라미터 표를 만듭니다. 하나의 진실 원천:
주석을 바꾸면 스키마를 다시 생성하고, 그에 따라 대시보드의 폼도 함께 바뀝니다.

형식은 엄격합니다: `## @param {type} name=default-value - Description.`

파라미터는 의도적으로 적습니다. 새 파라미터 하나하나가 폼의 필드 하나가 늘어나는 것이고, 애플리케이션을
잘못 배포할 방법이 하나 더 늘어나는 것이며, 여러분이 유지해야 할 분기가 하나 더 느는 것입니다. 좋은 차트는
설치마다 정말로 달라지는 것만 설정하게 하고, 그 이상은 두지 않습니다.

### `values.schema.json` — 무엇을 유효하다고 볼 것인가

스키마는 무엇이든 클러스터로 가기 **전에** Helm이 검사합니다. 그 자리에서 확인해 보십시오. 숫자
파라미터에 문자열을 슬쩍 넣어 보는 것입니다.

```bash
# template = "차트에서 매니페스트를 조립해 출력해라", 클러스터는 건드리지 않습니다:
#   gp                    차트가 명목상 배포되는 릴리스 이름
#   chart                 차트가 든 폴더
#   --set replicas=abc    명령줄에서 바로 파라미터 하나를 덮어쓰기
helm template gp chart --set replicas=abc
```

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
guest-pass:
- at '/replicas': got string, want integer
```

오류는 bastion에서 0.5초 만에 잡힙니다. 스키마가 없었다면 이것은 클러스터로 넘어가, 절대 생성되지 않는
Deployment로 바뀌고, 화면 세 개짜리 메시지를 남겼을 것입니다.

바로 이 스키마가, 한 글자도 다르지 않게, `ApplicationDefinition`으로 들어갑니다. 그리고 거기서
대시보드의 생성 폼으로 자라납니다.

### `templates/configmap.yaml` — 페이지

```yaml
    <h1>{{ .Values.greeting }}</h1>
```

애초에 템플릿 도구가 존재하는 이유가 바로 이것입니다. `values`의 값이 렌더링 시점에 매니페스트로
들어갑니다. Helm이 없었다면 자회사마다 매니페스트 복사본을 하나씩 두고 손으로 고쳐야 했을 것입니다.

### `templates/deployment.yaml` — 애플리케이션

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

모두가 잊어버리는, 그리고 나중에 디버깅 한 시간을 잡아먹는 그 한 줄입니다.

Kubernetes는 **ConfigMap이 바뀌어도 Pod을 재시작하지 않습니다**. 여러분이 텍스트를 고치고 업데이트를
돌리면, 대시보드는 "업데이트됨"이라고 표시하는데, 페이지에는 여전히 예전 인사말이 나옵니다. 설정의 해시가
담긴 이 애노테이션은 설정과 함께 바뀌고, Pod 템플릿 안의 애노테이션이 바뀌는 것은 이미 Pod 자체가 바뀌는
것이므로, 클러스터가 Pod을 다시 만듭니다.

```yaml
            requests:
              cpu: {{ .Values.resources.cpu | quote }}
```

여기서 `quote`는 필수입니다. 따옴표가 없으면 YAML은 `100m` 값은 문자열로 읽지만 `1`은 숫자로 읽어서, 두
경우 중 하나는 타입 오류가 납니다. 따옴표는 이 부류의 문제를 한꺼번에 없애 줍니다.

### `templates/service.yaml` — 주소

```yaml
  type: {{ if .Values.external }}LoadBalancer{{ else }}ClusterIP{{ end }}
```

불리언 파라미터 하나가 애플리케이션이 클러스터 바깥의 주소를 얻을지 말지를 결정합니다. Cozystack의 내장
애플리케이션도 정확히 이렇게 만들어져 있습니다. 대부분에 바로 이 의미의 `external` 필드가 있습니다.
카탈로그에서는 남들의 관례를 따르는 것이 좋습니다. 여러분보다 앞서 관리형 서비스를 세 개 배포해 본
사람은 이 필드를 같은 자리에서, 같은 이름으로 찾을 것입니다.

</details>

## 2단계. 차트를 로컬에서 검증하기

📍 **어디에서:** bastion에서(그 터미널에서). 이 작업에는 클러스터가 필요 없습니다.

먼저 린터입니다. 린터는 차트를 파일 묶음으로 읽으면서 구조적 오류를 잡아냅니다. 잘못된 들여쓰기,
빠뜨린 필수 필드, 파싱되지 않는 템플릿 같은 것들입니다.

```bash
cd labs/13-catalog
# lint = "패키지의 형식 오류와 필수 필드를 검사해라"
#   chart   차트 폴더로 가는 경로; 그 안에서 Helm은 Chart.yaml, values.yaml
#           그리고 templates/ 폴더를 기대합니다
helm lint chart
```

**여러분이 보게 될 것:**

```
==> Linting chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

`[INFO]`는 오류가 아니라 지적입니다. 차트에 `icon` 필드가 없다는 것입니다. Cozystack 카탈로그에서는
어차피 필요하지 않습니다. 아이콘은 `ApplicationDefinition`에서 가져오며, 거기까지는 뒤에서 다룹니다.

이제 렌더링입니다. 템플릿이란 값의 일부가 `{{ .Values.replicas }}` 형태의 치환으로 대체된 매니페스트입니다.
렌더링은 템플릿을 완성된 매니페스트로 바꾸는 것입니다. Helm이 `values.yaml`에서 값을 가져와 텍스트에
끼워 넣고 결과를 출력합니다.

```bash
# main — 릴리스 이름, 즉 이 특정한 차트 배포의 이름입니다. 이 이름은 생성되는 객체의
# 이름에 들어가므로, 나란히 놓인 두 설치가 이름으로 충돌하지 않습니다.
helm template main chart
```

출력은 평범한 매니페스트, 첫 랩들에서 여러분이 손으로 쓴 것과 같은 것들입니다. Helm에 마법 같은 것은
없습니다. 텍스트에 값을 끼워 넣을 뿐입니다.

파라미터가 정말로 매니페스트까지 도달하는지 확인해 보십시오. 서로 다른 값으로 두 번 렌더링하고, 출력에서
바뀌어야 할 그 줄만 남깁니다.

```bash
# --set replicas=5 는 실행 한 번 동안 values.yaml의 값을 덮어씁니다.
# | grep 'replicas:' — 전체 출력에서 이 단어가 든 줄만 남깁니다.
helm template main chart --set replicas=5 | grep 'replicas:'
# 불리언 파라미터도 마찬가지: external이 매니페스트에 어떤 Service 타입이 들어갈지를 결정합니다
helm template main chart --set external=true | grep 'type:'
```

```
  replicas: 5
  type: LoadBalancer
          type: RuntimeDefault
```

세 번째 줄은 오류도 아니고 여러분의 오타도 아닙니다. `grep`은 텍스트 전체에서 단어를 찾는데, `type:`은
보안 요구 사항(`seccompProfile`)에도 나타납니다. `grep`이 YAML 구조를 이해하지 못한다는 유용한
상기입니다. grep은 필드가 아니라 줄을 찾습니다.

⚠️ **`helm template`은 클러스터로 아무것도 보내지 않고, 클러스터 쪽에서 아무것도 검사하지 않습니다.**
텍스트를 렌더링할 뿐입니다. `helm template`을 통과한 매니페스트도 클러스터에게 거부될 수 있습니다.
예를 들어 CRD가 없어서 그럴 수 있습니다. 이것은 값싼 검사이지, 완전한 검사가 아닙니다.

## 3단계. ApplicationDefinition 뜯어보기

차트는 애플리케이션을 배포할 줄 압니다. 하지만 카탈로그는 아직 그것을 모릅니다. 「게스트 패스」가
대시보드에 목록으로 나타나고 API에서 하나의 객체 유형이 되려면, 파일이 하나 더 필요합니다.

그 파일은 바로 옆에 있습니다 — `applicationdefinition.yaml`.

<details>
<summary><b>더 자세히: applicationdefinition.yaml 안에 무엇이 있는가</b></summary>

```yaml
apiVersion: cozystack.io/v1alpha1
kind: ApplicationDefinition
metadata:
  name: guest-pass
```

여기에 **없는** 것에 주목하십시오: `namespace` 필드입니다. 이것이 바로 그 객체의 cluster-scoped
성질입니다. 클러스터당 하나이고, 그것이 만들어 내는 카탈로그 항목은 모든 테넌트가 한꺼번에 보게 됩니다.

### `application` 블록 — API에서 어떻게 보이는가

```yaml
  application:
    kind: GuestPass
    plural: guestpasses
    singular: guestpass
```

이 파일을 적용하고 나면 클러스터에 새로운 유형의 객체가 나타납니다. "통합"도 "플러그인"도 아닌, 평범한
`kubectl`로 다루는 온전한 유형입니다. 관리자가 정의를 적용하는 순간 이 두 명령은 어느 테넌트에서든
동작합니다:

```bash
# get = "무엇이 있는지 보여줘". guestpasses는 아래 plural 필드에 있는 바로 그 이름입니다:
#   -n tenant-workshopXX   어느 namespace에서 볼지; XX는 자신의 번호로 바꾸십시오
kubectl get guestpasses -n tenant-workshopXX
# describe = "객체 하나에 관한 모든 것을 보여줘": 파라미터, 상태, 최근 이벤트.
# 여기서 main은 유형의 이름이 아니라 주문된 특정 애플리케이션의 이름입니다.
kubectl describe guestpass main -n tenant-workshopXX
```

`plural`은 명령과 API URL에 들어가는 것입니다. `singular`는 `kubectl describe`에 쓰는 것입니다. 둘 다
소문자로, 공백 없이 씁니다 — 이것은 스타일의 문제가 아니라 Kubernetes의 요구 사항입니다.

```yaml
    openAPISchema: |-
      {"title":"Chart Values","type":"object","properties":{...}}
```

차트에 `values.schema.json` 파일로 들어 있는 바로 그 스키마인데, JSON 한 줄로 적혀 있을 뿐입니다.
이것은 두 곳에서 동작합니다. API는 유효하지 않은 값을 거부하고, 대시보드는 이것을 바탕으로 생성 폼을
그립니다 — 필드 유형, 기본값, 힌트까지.

⚠️ **여기의 스키마와 차트의 스키마는 일치해야 합니다.** 둘 사이에 자동 연결은 없습니다. 이것은 두 개의
파일이며, 그것을 동기화하는 것은 여러분의 몫입니다. 서로 어긋나면 대시보드의 폼은 어떤 필드를 보여주는데
차트는 다른 필드를 기대하게 됩니다. `check.sh`가 여러분 대신 둘을 대조해 주지만, 이 검사를 습관으로
들이는 것이 좋습니다.

### `release` 블록 — 무엇을 배포하는가

```yaml
  release:
    prefix: guest-pass-
```

릴리스 이름은 접두사와 객체 이름으로 만들어집니다. `main`이라는 이름의 `GuestPass`는 `guest-pass-main`
릴리스로 배포됩니다. 이 필드는 필수입니다. 서로 다른 애플리케이션의 릴리스가 한 namespace에서 이름으로
충돌하지 않도록 하기 위한 것입니다. `main`이라는 이름은 흔하지만, `guest-pass-main`은 오직 여러분의
것입니다.

```yaml
    labels:
      sharding.fluxcd.io/key: tenants
```

Cozystack의 서비스 레이블입니다. 이것을 기준으로 테넌트들의 릴리스가 Flux의 핸들러들에 분배됩니다. 이것이
없으면 릴리스를 처리해 줄 주체가 없어서, 릴리스는 대기 상태로 매달려 있게 됩니다. 여기는 창의성을 발휘할
자리가 아닙니다 — 그대로 복사하십시오.

```yaml
    chartRef:
      kind: HelmChart
      name: cozystack-guest-pass
      namespace: cozy-public
```

차트를 어디에서 가져올지입니다. `kind`의 유효한 값은 셋입니다: `OCIRepository`, `HelmChart`,
`ExternalArtifact`.

외부 카탈로그는 보통 `GitRepository` → `HelmChart` 사슬을 거쳐 들어옵니다. 관리자가 여러분의 저장소를
`cozy-public` namespace에 소스로 추가하면, Flux가 거기서 차트를 꺼내고, `ApplicationDefinition`이 그
차트를 참조합니다. `cozystack/external-apps-example`에 바로 이 경로가 나와 있으며, 여기서 시작하는 것이
합리적입니다.

⚠️ **`chartRef`의 이름은 여러분 혼자 지어내는 것이 아닙니다.** 관리자가 소스를 등록하는 방식과 일치해야
합니다. 파일을 보내기 전에 그것들을 합의하십시오 — 그러지 않으면 정의는 적용되는데 배포할 것이 없고,
오류는 "생성"을 처음 누른 사람에게서만 드러납니다.

### `dashboard` 블록 — 인터페이스에서 어떻게 보이는가

```yaml
  dashboard:
    category: PaaS
    singular: Guest Pass
    plural: Guest Passes
    description: Internal guest pass service for employees and reception
    tags: [internal, web]
```

`category`는 카탈로그 섹션입니다. Cozystack은 다섯 개를 씁니다: `PaaS`, `IaaS`, `NaaS`,
`Administration`, `Networking`. 기존 것을 고르십시오. 자기만의 섹션이란 항목이 하나뿐인 섹션이며, 거기서는
아무도 여러분의 애플리케이션을 찾지 못할 것입니다.

여기의 `singular`와 `plural`은 공백과 대문자가 있는 **사람이 읽는** 이름입니다. `application` 블록의
것들과 혼동하지 마십시오. 그것들은 API를 위한 것이고, 이것들은 눈을 위한 것입니다.

```yaml
    icon: PHN2ZyB3aWR0aD0iMTQ0IiBoZWlnaHQ9IjE0NCIgdmlld0JveD0iMCAwIDE0NCAxNDQi...
```

아이콘은 base64로 인코딩된 SVG입니다. 경로도 링크도 아닌, 인코딩된 것입니다. 대시보드는 그것을 내려받으러
어디로도 가지 않습니다. 그림은 객체 자체 안에 들어 있습니다.

원본은 바로 옆 `icon.svg`에 있고, 완성된 문자열은 `icon.b64`에 있습니다. 원본을 수정했다면 문자열을 다시
만들어야 합니다. 인코더는 기본적으로 출력을 여러 줄로 나누는데, `icon` 필드에는 끊기지 않는 한 줄이
필요합니다 — 그래서 줄바꿈은 별도의 단계에서 제거합니다.

```bash
# base64 = 이진 파일을 글자, 숫자, 그리고 + / = 기호로 이루어진 문자열로 바꾸기
#   -i icon.svg   무엇을 인코딩할지 (macOS와 BSD용 플래그 표기)
# tr -d '\n' = 출력에서 모든 줄바꿈을 없애 한 줄로 이어 붙이기
base64 -i icon.svg | tr -d '\n'
```

Linux에서는 같은 명령의 플래그가 다릅니다: `base64 -w0 icon.svg`, 여기서 `-w0`은 "출력을 전혀 줄바꿈하지
말라"는 뜻입니다. GNU와 BSD의 플래그 표기는 여기서 서로 일치하지 않습니다.

144×144 캔버스 크기는 플랫폼의 내장 아이콘과 같습니다. 그 이상은 필요 없습니다. 카탈로그에서는 작게
그려집니다.

```yaml
    keysOrder: [["apiVersion"], ["kind"], ["metadata"], ..., ["spec", "replicas"], ...]
```

객체의 YAML 표현에서 필드가 놓이는 순서입니다. 겉치레이지만, 이것이 없으면 필드가 아무렇게나 늘어섭니다 —
드물게 쓰는 `resources`가 먼저, 핵심인 `replicas`가 뒤에 — 그래서 폼이 될 수 있는 것보다 읽기 나빠집니다.

</details>

## 4단계. 적용을 시도하고 — 거부당하기

📍 **어디에서:** bastion에서, 테넌트 접근 권한으로.

파일은 준비되었고 문법도 올바릅니다 — 마치 권한이 있는 것처럼 적용을 시도해 봅시다. 거부는 `kubectl`이
아니라 클러스터에게서 오며, 거부 텍스트에는 정확히 무엇이 부족했는지가 적혀 있습니다.

```bash
# 테넌트 접근 권한 — 워크숍 내내 다뤄 온 바로 그것입니다
export KUBECONFIG=~/.kube/config
# apply = "파일에 쓰인 대로 클러스터를 맞춰라"; -f — 파일에서 읽기
kubectl apply -f applicationdefinition.yaml
```

**여러분이 보게 될 것:**

```
Error from server (Forbidden): error when creating "applicationdefinition.yaml":
applicationdefinitions.cozystack.io is forbidden: User "workshopXX" cannot create
resource "applicationdefinitions" in API group "cozystack.io" at the cluster scope
```

거부는 예상된 일입니다. 랩 초반에 이미 말했습니다. 여기서 중요한 것은 마지막 네 단어입니다 — **at the
cluster scope**.

<details>
<summary><b>답과, 이 오류보다 더 넓은 교훈</b></summary>

테넌트 안에서 여러분의 권한은 namespace 안의 권한입니다. 여러분은 자기 몫의 온전한 주인입니다.
클러스터, 데이터베이스, VM을 띄우고, 지우고, 망가뜨리고, 고칩니다. 여러분의 객체는 어느 하나도 이웃에게
보이지 않고 이웃을 방해하지 않습니다.

`ApplicationDefinition`은 다르게 만들어져 있습니다. 그것은 **모든 테넌트의 카탈로그를 한꺼번에** 바꿉니다.
스키마에 오류가 있는 애플리케이션을 여러분이 적용하면, 다른 부서 사람들이 그것을 보고 배포하려 들게 됩니다.
기존 것과 같은 이름을 붙인 애플리케이션은 기존 것을 망가뜨립니다.

그래서 경계가 바로 여기에 지나가며, 이것은 불신에 관한 것이 아닙니다. vSphere에서도 같았습니다. 자기 풀
안의 자기 VM은 여러분이 직접 만들었지만, 공용 Content Library의 내용과 그에 대한 권한은 — 아니었습니다.

**실무에서 무엇을 할 것인가.** 플랫폼 관리자에게 파일 둘과 합의 하나를 넘기십시오:

| 무엇을 넘기는가 | 왜 |
|---|---|
| `applicationdefinition.yaml` | 관리자가 적용할 객체 자체 |
| 차트가 든 저장소 링크 | 관리자가 이것으로 `cozy-public`에 소스를 만듭니다 |
| `chartRef`의 합의된 이름 | 정의가 차트를 찾도록 |

그리고 보내기 전에 두 파일이 모두 이상 없는지 확인하십시오 — 여기서는 피드백 고리가 길기 때문입니다.
관리자가 적용하는데, 오류는 세 번째 사람이 보게 됩니다.

</details>

거부는 파일 자체의 오류 때문에 올 수도 있었습니다. 둘을 갈라 봅시다. 먼저 권한을 물어보고, 그다음
`kubectl`이 파일을 어디로도 보내지 않은 채 통째로 파싱하게 합니다.

```bash
# auth can-i = "나에게 이게 허용됩니까?". 답은 yes 또는 no이고, 클러스터는 바뀌지 않습니다.
kubectl auth can-i create applicationdefinitions
# --dry-run=client = "파일을 파싱해서 무엇이 나올지 보여주되, 클러스터로는 가지 마라".
# client는 모든 검사가 bastion에서 이뤄지고 클러스터는 그에 대해 알지도 못한다는 뜻입니다.
kubectl apply -f applicationdefinition.yaml --dry-run=client
```

**여러분이 보게 될 것.** 첫 번째 명령은 — `no`. 두 번째는 —
`applicationdefinition.cozystack.io/guest-pass created (dry run)`: 파일은 파싱되고, 문법은 이상 없으며,
문제는 정말로 권한에 있습니다.

⚠️ **`--dry-run=client`는 문법만 검사합니다.** 클러스터에게는 아무것도 묻지 않습니다.
`--dry-run=server`라면 물어보겠지만, 그러려면 지금 없는 바로 그 권한이 필요합니다.

## 5단계. 자회사들이 보게 될 것

관리자가 정의를 적용하면 카탈로그에 항목이 늘어납니다. 그 순간부터 어느 테넌트든 Redis를 배포했던 것과
똑같이 「게스트 패스」를 배포합니다: **Create application** → `Guest Pass` → 여러분의 네 파라미터로 이루어진
폼 → 버튼.

또는 텍스트로 — 이 폴더의 `guestpass-example.yaml` 파일입니다:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: GuestPass
metadata:
  name: main
  namespace: tenant-workshopXX
spec:
  replicas: 2
  greeting: "Order a pass for your guest"
  external: false
```

그룹에 주목하십시오: `apps.cozystack.io` — `Bucket`이나 `VMInstance`와 같은 그룹입니다. 여러분의
애플리케이션은 한쪽 구석이 아니라 내장 애플리케이션들과 **같은 줄에** 자리 잡았습니다. 테넌트의 애플리케이션
목록에도 똑같이 보이고, 리소스도 똑같이 집계되며, 권한도 똑같이 동작합니다.

⚠️ 관리자가 정의를 등록하기 전에는 이 파일을 적용할 수 없습니다: `kubectl`은
`no matches for kind "GuestPass"`라고 답합니다 — 아직 클러스터에 그런 객체 유형이 없기 때문입니다.

## 6단계. 이 모든 것을 손으로 쓰지 않는 법

이 랩에서 여러분이 뜯어본 것은 모두 뼈대입니다: `Chart.yaml`, `values.yaml`, 스키마, 템플릿, 올바른
이름과 레이블을 갖춘 `ApplicationDefinition`. 파일의 절반은 어디서나 똑같은 필수 필드이며, 그것들은
쓰는 것보다 틀리기가 더 쉽습니다.

이를 위한 완성된 도구가 있습니다.

| 무엇 | 어디에 | 왜 |
|---|---|---|
| `cozystack/ccp` 저장소 | github.com/cozystack/ccp | Claude Code용 플러그인과 스킬 모음 |
| `cozystack` 플러그인 | 거기에서 | Claude Code에게 Cozystack 패키지 구조를 가르칩니다 |
| `external-app-create` 스킬 | 플러그인 안에 | 외부 애플리케이션 뼈대 전체를 생성합니다 |
| 예제 저장소 | github.com/cozystack/external-apps-example | 차트 빌드와 게시까지 담긴 동작하는 예제 |

스킬은 애플리케이션 이름, kind, 카테고리, 파라미터를 물어보고 — 완성된 파일 트리를 펼쳐 놓습니다: 스키마가
든 차트, 올바른 접두사와 레이블을 갖춘 `ApplicationDefinition`, 빌드용 Makefile.

이 모든 것을 손으로 뜯어본 의미가 사라지는 것은 아닙니다. 생성된 뼈대도 여전히 읽고 고쳐야 하는데, 이해하지
못하는 것을 고치는 것은 알려진 최악의 작업 방식입니다.

## 점검

📍 **어디에서:** bastion에서, `kubectl`로 작업하던 바로 그 터미널 창에서.

스크립트는 **로컬에서** 동작하며 클러스터를 건드리지 않습니다: 차트가 린터를 통과하는지, 렌더링되는지,
파라미터가 정말로 매니페스트까지 도달하는지, `ApplicationDefinition`이 파싱되고 필수 필드를 모두 담고
있는지, 아이콘이 SVG로 디코딩되는지 — 그리고 무엇보다, 정의의 스키마가 차트의 스키마와 일치하는지를
검사합니다.

```bash
# 이름 앞의 ./ 는 "현재 폴더의 파일", 즉 labs/13-catalog의 파일을 뜻합니다
./check.sh
```

⚠️ **Windows에서는 스크립트를 PowerShell이 아니라 WSL에서 실행합니다** — 어떻게 설치하는지는 랩 0의
처음에 적혀 있습니다. WSL 없이도 랩은 완료할 수 있지만, 아티팩트 리포트는 나오지 않습니다.

`KUBECONFIG`가 설정되어 있으면, 스크립트는 겸사겸사 클러스터에 권한을 물어보고 여러분에게 정의를 적용할
자격이 없음을 확인합니다. 스크립트는 권한이 없다는 것을 오류가 아니라 예상된 결과로 간주합니다.

## 정리

정리할 것이 없습니다: 여러분은 클러스터에 아무것도 만들지 않았습니다. 이것은 워크숍에서 흔적을 남기지 않는
유일한 랩이며, 그것이 이 랩의 특징입니다 — 플랫폼 팀의 작업은 대부분 정확히 이렇게 보입니다: 텍스트, 리뷰,
그리고 적용에 놓이는 남의 손.

`chart/`와 `applicationdefinition.yaml` 파일은 챙겨 가십시오. 이것은 쓸 만한 출발점이며, 여기서 여러분의
카탈로그에 올릴 진짜 애플리케이션이 자라날 수 있습니다.

## 이제 우리가 할 수 있는 것

- 애플리케이션을 파라미터 스키마가 있는 Helm 차트로 패키징하고 로컬에서 검증하기
- `ApplicationDefinition`을 작성하고 각 블록의 목적을 설명하기
- 왜 카탈로그가 공용이고 왜 테넌트에게 그에 대한 권한이 없는지 이해하기
- 관리자가 파일을 한 번에 적용하도록 인계를 준비하기
- 무엇으로 뼈대를 생성하고 어떤 예제를 볼지 알기

## 그리고 vSphere였다면 이것은

Content Library와 입력 필드가 있는 OVF 템플릿입니다. 그 메커니즘은 보이는 것보다 훨씬 닮았습니다: 한 팀이
템플릿을 준비하고, 다른 팀이 공용 라이브러리에 넣고, 또 다른 사람들이 배포합니다.

차이는 무엇이 나오느냐에 있습니다. OVF 템플릿은 디스크가 달린 기계입니다: 배포하고 나면 그때부터 혼자
살아가고, 갱신은 복사본마다 손으로 하게 됩니다. `ApplicationDefinition`은 차트가 뒤를 받치는 설명입니다:
차트를 갱신하고, 버전을 올리면, 모든 설치가 하나의 메커니즘으로 갱신됩니다.

**솔직히 vSphere가 더 편한 지점.** Content Library는 완성된 인터페이스입니다: 파일을 넣고, 권한을 나눠
주면, 끝입니다. 여기서는 저장소를 만들고, 차트 빌드와 게시를 구성하고, 소스 이름을 관리자와 합의해야
합니다 — 그리고 이 모든 것이 카탈로그에 무엇이 나타나기 전에 이뤄져야 합니다. 진입 장벽이 더 높고, 첫
애플리케이션에는 한 시간이 아니라 하루가 듭니다.

이것이 본전을 뽑는 것은 두 번째, 세 번째 애플리케이션에서, 그리고 특히 첫 갱신에서입니다. 다섯 자회사로
퍼진 애플리케이션을 차트로 갱신하는 것과, 같은 애플리케이션을 서로 어긋난 다섯 OVF 복사본에서 갱신하는
것은 — 작업량이 다릅니다. 자릿수가 다릅니다.
