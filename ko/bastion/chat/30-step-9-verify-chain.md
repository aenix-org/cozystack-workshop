## 30. 9단계: 전체 체인 검증하기

**진실의 순간**

⚠️ **먼저 — 가상 머신 안에서 — firewalld를 끄십시오.** 마이그레이션된 CentOS는
과거의 규칙을 그대로 가져와 외부에는 SSH만 노출합니다. 애플리케이션 포트는 닫혀 있고,
외부에서는 이것이 "애플리케이션이 죽었다"처럼 보입니다.

```bash
systemctl stop firewalld
systemctl disable firewalld
```

바로 그 자리에서, 머신 내부에서 애플리케이션이 살아 있는지 확인하십시오:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — 애플리케이션이 응답하는 것입니다. `503` — 네트워크 단계로 돌아가십시오. 여기서
`localhost`는 당신이 앉아 있는 바로 그 머신입니다: 애플리케이션이 자기 자신을 검사하는 것입니다.

📍 **다음 — 도메인 이름으로 외부에서 확인.** 이 경로에서는 포트 포워딩이 필요 없습니다:
강사가 당신의 테넌트에 `Ingress`를 미리 만들어 두었고, 머신 내부의 애플리케이션이
`8080`에서 리스닝하기 시작하는 순간, 상점이 `https://app.workshopXX.workshop.aenix.io`
주소로 게시됩니다 (`XX`는 당신의 번호). 랩톱의 브라우저에서 열어 보거나 — bastion에서 바로
`curl`로 확인하십시오:

```bash
# health
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

# 주문 생성
curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# 기록되었는지 확인
curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

⚠️ app-VM이 아직 올라오지 않았거나 여전히 부팅 중인 동안에는 도메인이 `503`을 응답합니다 — 이것은
정상입니다: `Ingress`가 백엔드를 기다리는 것입니다. `200`이 나타나면 — 내부의 머신이 `8080`에서
리스닝하고 있는 것입니다.

주문이 생성되었다면 — 당신은 전체 경로를 끝까지 걸어온 것입니다. 애플리케이션은 VMware에서 넘어와,
클러스터에서 실행되고, 관리형 데이터베이스에 쓰며, 관리형 큐로 이벤트를 보냅니다.

30분 전만 해도 이 시스템은 ESXi에서 살고 있었습니다.
