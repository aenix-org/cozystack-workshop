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
| 1 | 우리가 실제로 하려는 일 | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | 작은 용어집: 여러분 쪽에서는 뭐라고 부르고 여기서는 뭐라고 부르는가 | [`02-glossary.md`](02-glossary.md) |
| 3 | 시작하기 전에: 준비물 | [`03-prerequisites.md`](03-prerequisites.md) |
| 8 | bastion(공유 VM)에 로그인하기 | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 10 | 자료는 이미 bastion에 있습니다 | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | 파일 맵: 무엇이 어디에 있고 어디서 실행되는가 | [`11-file-map.md`](11-file-map.md) |
| 12 | 페이즈 1. vSphere에서 이미지 내보내기 | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | 자세히 보기: 01-bucket.yaml 안에는 무엇이 있나 | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | 1단계: 나만의 스토리지 | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | 자세히 보기: 02-conversion-vm.yaml 안에는 무엇이 있는가 | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | 2단계: 변환기 머신 | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | 자세히 살펴보기: convert.sh 안에는 무엇이 있나 | [`17-convert-script.md`](17-convert-script.md) |
| 18 | 3단계: 이미지 변환 | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | 페이즈 2. 새 보금자리에서 머신 깨우기 | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | 자세히 살펴보기: 03-app-vm.yaml 안에는 무엇이 들어 있나 | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | 4단계: 여러분의 가상 머신 | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | 페이즈 3. 동물원 버리기 | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | 자세히 살펴보기: 04-managed.yaml 안에는 무엇이 있는가 | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | 5단계: 카탈로그에서 데이터베이스와 큐 올리기 | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | 6단계: 머신 내부의 네트워크를 고칩니다 | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | 첫 번째 점검: 일단 띄워 보고 오류를 잡아낸다 | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | 7단계: 애플리케이션을 매니지드 서비스로 전환하기 | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | 8단계: 애플리케이션이 여전히 실패하는 이유 | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | 8단계: 클라이언트 설치 및 스키마 적용 | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | 9단계: 전체 체인 검증하기 | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | 무언가 동작하지 않을 때 | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | 워크숍이 끝난 뒤 | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
