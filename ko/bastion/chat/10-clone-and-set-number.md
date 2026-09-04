## 10. 자료는 이미 bastion에 있습니다

**클론할 것이 없습니다**

📍 **위치:** 방금 SSH로 로그인한 bastion(공유 VM) 위입니다.

자료 폴더는 이미 여러분의 홈 디렉터리에 놓여 있고, **여러분의 테넌트 번호도 이미 채워져 있습니다**. `tenant-workshopXX` 자리표시자는 bastion을 준비할 때 여러분의 `tenant-workshopNN`으로 이미 교체되었습니다 — 찾아서 바꿀 것은 없으니, 파일을 있는 그대로 바로 적용하면 됩니다.

폴더로 들어가서 안에 무엇이 있는지 살펴봅니다:

```bash
cd ~/workshop
ls manifests scripts
```

매니페스트 네 개와 스크립트 네 개 — 파일 맵에 나왔던 바로 그것들이 보여야 합니다. 채워진 번호가 여러분의 것인지 확인합니다:

```bash
grep -m1 namespace manifests/01-bucket.yaml
```

`namespace:` 줄에는 `tenant-workshopXX`가 아니라 여러분의 `tenant-workshopNN`이 들어 있을 것입니다.

**길을 잃었다면**, 돌아오는 방법은 언제나 같습니다:
```bash
cd ~/workshop
```

**편집할 때 파일을 무엇으로 여는가.** 이것은 딱 한 번 필요합니다 — 세 번째 단계에서 `manifests/03-app-vm.yaml`에 presigned URL을 붙여넣을 때입니다. `nano`면 충분합니다:
`nano manifests/03-app-vm.yaml` (저장: `Ctrl+O`, `Enter`, 종료: `Ctrl+X`).

의도적으로 남겨둔 유일한 자리표시자는 `manifests/03-app-vm.yaml`의 다음 줄,
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` 입니다. 이 URL은 이미지를 변환하면 받게 됩니다. 지금은 그저 그것이 거기서 여러분을 기다리고 있다는 것만 알아두면 됩니다.
