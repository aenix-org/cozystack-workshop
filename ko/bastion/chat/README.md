# 워크숍 채팅 메시지 — bastion 경로

한 파일이 하나의 메시지입니다. 한꺼번에 올리지 말고, 실습이 진행되는 흐름에 맞춰 올리세요.

이 세트는 **공유 bastion(공유 VM)을 통해** 작업하는 참가자들을 위한 것입니다.
도구와 클러스터 접근은 이미 bastion에 준비되어 있고, 테넌트 번호도 파일에 미리 채워져 있으며,
애플리케이션은 도메인 이름으로 확인합니다. 자신의 노트북에서 작업하는 세트는
[`../../laptop/chat/`](../../laptop/chat/)에 있습니다.

메시지 번호는 노트북 세트와 이어지는 연속 번호입니다(그래서 중간에 빠진 번호가 있습니다. 도구
설치에 관한 글은 여기서는 필요 없기 때문입니다).

| # | 메시지 | 파일 |
|---|---|---|
| 1 | 우리가 실제로 하려는 것 | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | 짧은 용어집: 여러분 쪽에서 부르는 이름과 여기서 부르는 이름 | [`02-glossary.md`](02-glossary.md) |
| 3 | 시작하기 전에: 무엇이 필요한가 | [`03-prerequisites.md`](03-prerequisites.md) |
| 8 | bastion에 로그인하기 | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 10 | 자료는 이미 bastion에 있습니다 | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | 파일 지도: 무엇이 어디에 있고 어디서 실행되는가 | [`11-file-map.md`](11-file-map.md) |
| 12 | 1단계. vSphere에서 이미지 꺼내오기 | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | 자세히 보기: 01-bucket.yaml 안에는 무엇이 있는가 | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | Step 1: 나만의 스토리지 | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | 자세히 보기: 02-conversion-vm.yaml 안에는 무엇이 있는가 | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | Step 2: 변환기 머신 | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | 자세히 보기: convert.sh는 무엇을 하는가 | [`17-convert-script.md`](17-convert-script.md) |
| 18 | Step 3: 이미지 변환하기 | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | 2단계. 새 보금자리에서 머신 띄우기 | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | 자세히 보기: 03-app-vm.yaml 안에는 무엇이 있는가 | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | Step 4: 여러분의 가상 머신 | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | 3단계. 동물원 버리기 | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | 자세히 보기: 04-managed.yaml 안에는 무엇이 있는가 | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | Step 5: 카탈로그에서 가져오는 데이터베이스와 큐 | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | Step 6: 머신 내부의 네트워크 고치기 | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | 첫 번째 확인: 실행해보려다 오류를 만나다 | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | Step 7: 애플리케이션을 매니지드 서비스로 연결하기 | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | Step 8: 애플리케이션이 여전히 죽는 이유 | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | Step 8: 클라이언트를 설치하고 스키마 적용하기 | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | Step 9: 전체 체인 검증하기 | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | 무언가 동작하지 않는다면 | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | 워크숍이 끝난 뒤 | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
