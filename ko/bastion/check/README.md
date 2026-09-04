# 검증 스크립트

모든 랩 폴더에는 `check.sh`가 들어 있습니다. 이 스크립트는 랩이 실제로 완료되었는지 —
"파일이 적용되었다"가 아니라 **실질적으로 동작하는지** — 를 검증합니다.

원할 때 언제든 직접 실행하면 됩니다. 결과는 터미널에 출력되는 리포트와, 어디에든 첨부할 수 있는
아티팩트 파일입니다. 커뮤니티 채팅, 인증 신청서, 자신의 메모 등 어디에나 붙일 수 있습니다.

## 실행 방법

```bash
cd labs/03-scale
./check.sh
```

여러분은 bastion(공유 VM)에 있으므로 — bastion(Linux)에는 `bash`, `kubectl`을 비롯해 필요한 모든 것이
이미 갖춰져 있어 따로 설치할 것이 없습니다. lab 클러스터에 접속하기 위한 인증 정보 — 랩 0에서 만든 바로 그
`lab.kubeconfig` — 는 스크립트가 `KUBECONFIG` 변수를 통해 찾아냅니다.

```bash
export KUBECONFIG=~/lab.kubeconfig
```

> 랩을 bastion이 아니라 자신의 Windows 컴퓨터에서 진행한다면 — WSL을 설치하는 방법과
> `lab.kubeconfig`를 받는 방법은 노트북 키트에 설명되어 있습니다:
> [`../../laptop/check/README.md`](../../laptop/check/README.md).

스크립트는 `KUBECONFIG` 변수를 보고 어디를 살펴봐야 할지 스스로 알아냅니다. 이 변수가 설정되어 있지
않으면, 그 사실을 알려주고 멈춥니다.

관리 클러스터의 테넌트에 접근해야 하는 랩에서는 추가로 `COZY_TENANT` 변수 — 여러분의 테넌트 이름,
예를 들어 `workshop07` — 도 필요합니다.

```bash
export COZY_TENANT=workshop07
./check.sh
```

## 결과물

터미널에는 — 검증 항목마다 한 줄씩 출력됩니다.

```
[  OK  ] application deployed and responding
[  OK  ] Pod name is injected into the page
[ FAIL ] autoscaling is not configured
         no HorizontalPodAutoscaler found for deployment/rickroll
         hint: apply hpa.yaml from this folder
```

⚠️ **리포트는 랩 폴더에 저장되며 날짜와 시간을 담고 있습니다.** 저장소가 공용이거나 검증을 여러 번
돌렸다면, 그곳에 여러 파일이 쌓입니다 — 다른 사람의 실행이나 이전 실행을 자신의 것으로 착각하지 않도록
이름에 담긴 시간을 확인하세요.

그 옆에는 `report-<lab>-<date>.md` 파일이 생깁니다 — 같은 결과를 Markdown으로 담은 것으로,
수집된 증거도 함께 들어 있습니다: 버전, 명령 출력, 객체 이름. 이것이 바로 아티팩트입니다.

## 스크립트 작성자를 위한 요구사항

**적용했다는 사실이 아니라 실질을 검증합니다.** 나쁜 예: "Deployment 객체가 존재한다". 좋은 예:
"애플리케이션이 HTTP로 응답하고, 응답에 Pod의 이름이 들어 있다".

**모든 실패는 무엇을 해야 하는지 설명합니다.** 힌트 없는 `FAIL` 줄은 불량입니다. 독자는 바로
막혀 있기 때문에 스크립트를 실행하는 것입니다.

**스크립트는 고치지도, 만들지도 않습니다.** 오직 읽기만 합니다. 유일한 예외는 네트워크 도달 가능성을
확인하기 위한 임시 Pod이며, 이 Pod는 사용 후 스스로 정리됩니다.

**macOS와 Linux에서 동작합니다.** GNU 전용 `sed -i`, `readlink -f`, `date -d`는 쓰지 마세요.
두 시스템 모두에서 테스트하세요.

**첫 오류에서 멈추지 않습니다.** 모든 검증을 끝까지 돌려 전체 그림을 보여줍니다.
`set -e`는 사용하지 마세요.

**비밀번호나 토큰을 출력하지 않습니다.** 값이 비밀이라면 — `<hidden>`이라고 쓰세요.

**멱등적입니다.** 열 번을 연속으로 실행해도 클러스터의 상태는 바뀌지 않습니다.

## 공용 라이브러리

`check/lib.sh` — 공용 함수로, 모든 스크립트의 시작 부분에서 불러옵니다.

- `ok "text"` / `fail "text" "hint"` / `warn "text"` — 결과 출력
- `need_kubeconfig` — `KUBECONFIG`가 설정되어 있고 클러스터가 응답하는지 확인
- `need_tenant` — `COZY_TENANT`가 설정되어 있는지 확인
- `evidence "heading" "value"` — 아티팩트에 증거 한 조각 추가
- `finish` — 결과를 종합하고, 리포트를 기록하고, 종료 코드를 반환

종료 코드: `0` — 모두 통과, `1` — 실패가 있음. 그래서 이 스크립트를 자동화에 사용할 수 있습니다.
