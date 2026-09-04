## 11. 파일 맵: 무엇이 어디에 있고 어디서 실행되는가

**한 번만 읽어 두면 — 그다음부터는 헷갈릴 일이 없습니다**

일이 벌어지는 세 곳을 머릿속에 담아 두십시오. **bastion**(SSH로 접속한 머신),
**변환 머신**, 그리고 **여러분의 app-VM** — 뒤의 두 개는 클러스터 내부에 생성됩니다.
저장소에는 두 종류의 파일이 있고, 각각 서로 다른 곳에서 실행됩니다.

**매니페스트 — `manifests/*.yaml`. bastion에서 적용합니다.**
클러스터에 무엇을 만들지 기술한 것입니다. 명령은 언제나 동일합니다: `kubectl apply -f <file>`.

• `01-bucket.yaml` — 이미지를 담을 스토리지 · 1단계
• `02-conversion-vm.yaml` — 변환 머신 · 2단계
• `03-app-vm.yaml` — 여러분의 app-VM · 4단계 (여기에 presigned 링크를 손으로 붙여 넣습니다)
• `04-managed.yaml` — 카탈로그에서 가져오는 Postgres와 Kafka · 5단계

**스크립트 — `scripts/*`. bastion이 아니라 클러스터 안의 머신 내부에서 실행됩니다.**
bastion 자체에서는 이 스크립트들을 실행하지 않습니다 — 매니페스트만 `kubectl`로 적용합니다.

• `convert.sh` — 변환 머신 내부 · 3단계
• `netfix-dhcp.sh` — 여러분의 app-VM 내부 · 6단계
• `connect-managed.sh` — 여러분의 app-VM 내부 · 7단계
• `orders-schema.sql` — app-VM 내부에서 만드는 데이터베이스용 테이블 · 8단계 (이건 쿼리로 직접
  입력할 것이고, 파일은 정확히 무엇이 생성되는지 볼 수 있도록 둔 것입니다)

**스크립트가 머신 안으로 들어가는 방식 — 그리고 그것이 왜 다른가.**

**변환 머신**에는 네트워크가 있으므로 파일을 스스로 내려받습니다. 저장소는
공개되어 있어 키가 필요 없습니다:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/convert.sh
```

**여러분의 app-VM에는 처음엔 네트워크가 아예 없습니다** — 바로 그 고장 난 상태를 우리가
6단계에서 고칩니다. 내려받을 대상도 없고 내려받을 수단도 없으며, 파일을 콘솔로 전달할 수도
없습니다. 그래서 `netfix-dhcp.sh`와 `connect-managed.sh`는 내려받지 않고 **손으로 직접
입력합니다**: 각각 명령이 두세 개뿐이고, 채팅으로 바로 쓸 수 있게 드리겠습니다. 저장소에 있는
파일 자체도 같은 내용이지만, 자세하게 풀어 쓰고 주석까지 달려 있습니다: 나중에 여러분이 직접
반복할 때 다시 읽어 보기에 편합니다.

⚠️ **매니페스트의 테넌트 번호는 이미 채워져 있습니다** — bastion을 준비하는 동안
`tenant-workshopXX` 자리표시자가 여러분의 번호로 교체되었습니다. 손으로 입력할 것은 없습니다.
여러분이 직접 채우는 것은 오직 `convert.sh`의 `bucketName`, `accessKey`, `secretKey`
(이 파일은 변환기 안으로 새로 내려받히며 `ВСТАВЬТЕ_...` 자리표시자가 들어 있습니다), 그리고
네 번째 단계에서 `manifests/03-app-vm.yaml`에 넣는 presigned 링크뿐입니다.
