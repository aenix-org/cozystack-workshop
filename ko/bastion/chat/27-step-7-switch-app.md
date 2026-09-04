## 27. 7단계: 애플리케이션을 매니지드 서비스로 전환하기

**하드코딩된 주소를 이름으로 교체하기**

📍 **위치:** 여러분의 머신(app-VM) 안, 재부팅 이후. bastion에서가 아닙니다.

📄 이것은 `scripts/connect-managed.sh`의 내용입니다. 이것도 직접 손으로 입력하세요 — 같은 이유에서이고, 명령이 세 개뿐이기 때문입니다.

머신 안에서 애플리케이션 설정을 엽니다:
```bash
cat /etc/orders/application.properties
```
바로 그 `192.168.10.30`과 `192.168.10.40`이 보일 겁니다. 이것이 모든 레거시 시스템의 고통입니다. 왜 하필 이 주소인지 이제 아무도 기억하지 못합니다.

이를 서비스 이름으로 교체하세요(`XX` 자리에 여러분의 번호를 넣으세요):
```bash
sed -i 's|192.168.10.30|postgres-db-rw.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
sed -i 's|192.168.10.40|kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
systemctl restart orders-api
```
(줄바꿈이 있는 하나의 명령이 아니라 두 개의 명령으로: 채팅에서 복사할 때 줄바꿈이 자주 사라져서 명령이 절반만 실행되는 경우가 많습니다)

확인합니다:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```
`200` — 애플리케이션이 데이터베이스와 큐를 모두 볼 수 있습니다. `503`이 나오면 네트워크 단계로 돌아가세요. 십중팔구 주소가 바뀌지 않은 것입니다.
