## 30. 9단계: 전체 체인 검증하기

**진실의 순간**

⚠️ **먼저 — 가상 머신 안에서 — firewalld를 끄십시오.** 마이그레이션된 CentOS는
과거의 규칙을 그대로 가져와 외부에는 SSH만 노출합니다. 애플리케이션 포트는 닫혀 있고,
랩톱에서 하는 포트 포워딩은 `no route to host`에 부딪힙니다 — 그리고 이것은
"애플리케이션이 죽었다"처럼 보입니다.

```bash
systemctl stop firewalld
systemctl disable firewalld
```

바로 그 자리에서, 머신 내부에서 애플리케이션이 살아 있는지 확인하십시오:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — 포트 포워딩을 해도 됩니다. `503` — 네트워크 단계로 돌아가십시오.

📍 **다음 — 랩톱에서.** 애플리케이션 포트를 자신에게 포워딩하십시오:
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```
이 명령이 있는 창을 닫지 마십시오: 터널은 이 명령이 실행되는 동안만 살아 있습니다.

⚠️ **여기서는 `vmi/`가 필수인데, `virtctl console`에서는 반대로 — 방해가 됩니다.** 이것은
오타나 우리의 변덕이 아닙니다: 두 명령은 대상 구문이 다릅니다. `port-forward`는 `type/name`을
요구하며, 접두사가 없으면 `target must contain type and name separated by '/'`라고 응답합니다.
`console`은 이름만 기대하며, 접두사가 있으면 `forbidden`이라고 응답합니다. `vmi`라는 단어를
머신의 이름으로 받아들이기 때문입니다.

virtctl이 클라이언트와 클러스터의 버전 차이에 대해 불평한다면 — 그것은 경고이지 오류가
아니며, 작업에 방해가 되지 않습니다.

포트 포워딩이 그래도 올라오지 않으면, 같은 터널을 머신의 Pod를 통해 만들 수 있습니다:
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <출력에서-나온-Pod-이름> 8080:8080
```

다른 터미널 창에서:
```bash
# health
curl -s http://localhost:8080/actuator/health

# 주문 생성
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# 기록되었는지 확인
curl -s http://localhost:8080/api/orders
```

주문이 생성되었다면 — 당신은 전체 경로를 끝까지 걸어온 것입니다. 애플리케이션은 VMware에서 넘어와,
클러스터에서 실행되고, 관리형 데이터베이스에 쓰며, 관리형 큐로 이벤트를 보냅니다.

30분 전만 해도 이 시스템은 ESXi에서 살고 있었습니다.
