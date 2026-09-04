## 21. 4단계: 여러분의 가상 머신

**여러분의 이미지로 머신 띄우기**

📍 **위치:** 노트북.

⚠️ **먼저 변환기 머신을 끄십시오** — 제 역할을 다했고 여러분 쿼터의 8Gi를 차지하고 있습니다.
이것을 치우지 않으면 새 머신이 `Pending` 상태로 멈추고, 마치 테스트베드가 고장 난 것처럼
보입니다. 지난 워크숍들에서는 거의 모두가 여기서 막혔습니다:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

이미지는 그대로 버킷에 남아 있습니다 — 바로 이것으로 머신을 띄울 것입니다.

이제 `manifests/03-app-vm.yaml`를 열고, presigned 링크를 `url` 필드에 붙여 넣은 뒤
적용하십시오:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

먼저 클러스터가 링크에서 이미지를 내려받아 여러 레플리카에 분산 배치합니다 — 1~2분 정도 걸립니다.
그런 다음 머신이 시작됩니다.

안으로 들어가 봅시다:
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

**여러분의 머신 접속 정보:**
```
login:    root
password: cozydemo
```

콘솔에서 나가려면 — `Ctrl+]`.

**여기에도 변환기 머신과 똑같은 한 쌍의 객체가 있습니다**, 다만 디스크를 카탈로그에서
가져오지 않고 여러분의 링크에서 내려받는다는 점만 다릅니다:

• **VM Disk** `app-1` — 10Gi, source = http, 바로 그 presigned URL
• **VM Instance** `app-1` — 프로필 `centos.7`, instance type `u1.medium`

이름이 겹치지만 괜찮습니다: 디스크와 머신은 서로 다른 객체 유형입니다. `virtctl`
명령에서 머신은 지난번과 마찬가지로 접두사를 붙여 지칭합니다: **`vm-instance-app-1`**.

🖱 **대시보드에서:** **1)** **VM Disk → Deploy new**: 이름 `app-1`, source = **http**,
URL 필드에는 presigned 링크, 크기 `10Gi`, storage class `replicated`.
**2)** **VM Instance → Deploy new**: 이름 `app-1`, instance type `u1.medium`,
프로필 `centos.7`, 디스크 — `app-1`. 콘솔은 머신 페이지의 **VNC** 버튼.

여러분이 방금 한 일을 눈여겨보십시오: 가상 머신을 텍스트로 기술하고 명령 하나로
적용했습니다. 이 파일을 저장소에 넣어 두면 클릭 한 번 없이 이런 머신을 백 대라도
띄울 수 있습니다.
