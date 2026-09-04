## 10. 자료 받아 오기와 자신의 번호 채워 넣기

**매니페스트 저장소**

📍 **위치:** 노트북의 터미널에서 진행합니다. 홈 디렉터리에 받아 둡니다 — 그러면 경로가 모두에게 동일해지고, 제가 여러분을 돕기도 더 쉽습니다.

**터미널을 어디서 여는가:**
• macOS — Spotlight(`Cmd+Space`)에서 "Terminal"을 입력
• Linux — 대부분의 환경에서 `Ctrl+Alt+T`
• Windows — "시작" 메뉴에서 "PowerShell"을 입력

**파일이 담긴 폴더를 받아 옵니다** (세 명령을 하나씩):
```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```
첫 번째 명령은 여러분을 홈 디렉터리로 옮기고, 두 번째는 그곳으로 자료 폴더를 내려받고, 세 번째는 그 안으로 들어갑니다. 이제부터 모든 명령은 **여기서** 실행합니다 —
명령 안의 경로는 이 폴더를 기준으로 작성되어 있습니다.

**무엇이 내려받혔는지 확인합니다:**
```bash
ls manifests scripts
```
매니페스트 네 개와 스크립트 네 개 — 파일 맵에 나왔던 바로 그것들이 보여야 합니다.

**터미널을 닫았거나 길을 잃었다면** — 돌아오는 방법은 언제나 같습니다:
```bash
cd ~/cozystack-migration-workshop/workshop
```
Windows에서도 경로는 같습니다: `cd $HOME\cozystack-migration-workshop\workshop`.
지금 어디에 있는지 확인하려면: `pwd` (PowerShell에서도 동작합니다).

⚠️ `/workshop` 꼬리는 필수입니다. 저장소에는 워크숍 자료 옆에 독립 실습이 담긴 `labs`
폴더가 있습니다 — 한 단계 위에서 멈추면 명령이 `manifests`도 `scripts`도 찾지 못합니다.

**편집할 때 파일을 무엇으로 여는가.** 매니페스트는 평범한 텍스트 파일이므로 무엇으로
열어도 됩니다:
• 터미널에서 — `nano manifests/03-app-vm.yaml` (저장: `Ctrl+O`, `Enter`, 종료: `Ctrl+X`)
• macOS에서 마우스로 — `open -a TextEdit manifests/03-app-vm.yaml`
• Windows에서 마우스로 — `notepad manifests\03-app-vm.yaml`
• VS Code가 설치되어 있다면 — `code .` 이 폴더 전체를 한 번에 열어 주며, 이게 가장 편합니다

⚠️ `.yaml` 파일을 Word나 Google Docs에서 열지 마십시오: 따옴표와 대시를 바꿔치기하고,
그러면 파일이 적용되지 않게 되며 오류가 설명 불가능해 보입니다.

모든 파일에는 `tenant-workshopXX` 자리표시자가 들어 있습니다. 여러분의 번호를 한 번에 전부 채워 넣으십시오,
그러지 않으면 매니페스트가 엉뚱한 곳으로 갑니다. 여러분의 로그인이 `workshop03`이라고 합시다:

**Linux**
```bash
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**macOS** (여기서는 `sed`의 문법이 다릅니다 — 빈 따옴표에 주의하십시오)
```bash
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**Windows** (PowerShell)
```powershell
Get-ChildItem -Recurse manifests,scripts -File | ForEach-Object {
  (Get-Content $_.FullName) -replace 'tenant-workshopXX','tenant-workshop03' | Set-Content $_.FullName
}
```

**자리표시자가 하나도 남지 않았는지 확인합니다:**
```bash
grep -rn tenant-workshopXX manifests scripts || echo "clean, you can continue"
```

명령이 건드리지 않는 곳이 하나 있습니다: `manifests/03-app-vm.yaml`의 다음 줄,
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` 입니다. 이 URL은 나중에 이미지를 변환하고 나면 받게 됩니다.
지금은 그저 그것이 거기서 여러분을 기다리고 있다는 것만 알아두면 됩니다.
