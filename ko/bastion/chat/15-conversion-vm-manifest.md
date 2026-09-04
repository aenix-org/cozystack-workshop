## 15. 자세히 보기: 02-conversion-vm.yaml 안에는 무엇이 있는가

이 파일에는 `---` 줄로 구분된 **두 개**의 객체가 들어 있습니다. YAML에서 여러 문서를 하나의
파일에 담는 방식입니다. 가상 머신은 디스크 없이 존재할 수 없으므로, 디스크는 별도로 기술되며
언제나 먼저 생성됩니다.

```yaml
kind: VMDisk
metadata:
  name: convert-tools
spec:
  source:
    image:
      name: ubuntu-20.04
  storage: 25Gi
  storageClass: replicated
```

`kind: VMDisk` — 디스크 그 자체, 독립된 객체입니다. 익숙해지려면 시간이 좀 걸립니다. vSphere에서
디스크는 머신의 속성이지만, 여기서는 미리 만들어 두고, 머신에 붙였다가, 떼어 내고, 다른 머신에
붙일 수 있는 독립적인 개체입니다.

`source.image.name: ubuntu-20.04` — 내용을 어디서 가져올지입니다. 위 지도에 나온 바로 그 이미지
카탈로그입니다. Cozystack이 `cloud-images.ubuntu.com`에서 공식 Ubuntu 20.04 클라우드 이미지를 이미
내려받아 로컬에 보관하고 있습니다. 여기서는 그것의 복사본을 만들어 달라고 요청하는 것입니다. 아무도
인터넷으로 가져오러 나가지 않으며, 복사본은 클러스터 내부에서 만들어집니다.

⚠️ **Ubuntu 버전은 의도적으로 지정된 것이므로 바꾸지 마세요.** 24.04에서는 머신이 부팅되지 않고,
22.04에서는 재패키징이 CentOS 7 내부의 오래된 RPM 패키지 데이터베이스에 걸려 넘어집니다 —
`virt-v2v`가 그것을 파싱하지 못합니다. 여러분이 겪지 않도록 이미 검증했습니다.

`storage: 25Gi` — 디스크 크기입니다. 카탈로그의 Ubuntu 이미지는 20Gi를 차지하며, **디스크는 이미지보다
커야 합니다.** 그렇지 않으면 복사가 중간에 끊기고, 그 디스크는 이후 `Terminating` 상태에서 멈춰
방해가 됩니다. 여유 공간이 필요한 또 다른 이유는, 내려받은 `app-1.ova`와 재패키징 결과물이 그 안에
동시에 놓이기 때문입니다.

`storageClass: replicated` — 저장 방식입니다. `replicated`는 서로 다른 노드에 여러 복사본을 둔다는
뜻입니다. 노드가 하나 꺼져도 데이터는 그대로 남습니다. vSphere의 스토리지 정책에 해당합니다.
`local`도 있는데, 더 빠르지만 단일 노드에만 존재합니다.

```yaml
kind: VMInstance
metadata:
  name: convert
spec:
  instanceType: u1.large
  instanceProfile: ubuntu
  runStrategy: Always
  disks:
    - name: convert-tools
```

`instanceType: u1.large` — 머신 크기, 즉 "CPU 몇 개, 메모리 얼마"가 미리 묶인 세트입니다. 여기서는
CPU 두 개와 8기가바이트입니다. 재패키징은 이미지를 조각 단위로 메모리에 올려 두고 메모리를 제대로
요구합니다.

`instanceProfile: ubuntu` — 이 게스트 시스템에 맞춘 가상 하드웨어 설정 모음입니다. 어떤 디스크
컨트롤러를 쓸지, 어떤 네트워크 카드를 쓸지, 시계를 어떻게 전달할지 같은 것들입니다. 가장 가까운
것은 VM 생성 마법사의 "Guest OS Type"으로, 이것 역시 선택한 시스템에 맞춰 열 몇 가지 설정을 조용히
바꿉니다.

`runStrategy: Always` — 머신을 켜진 상태로 유지하고, 만약 죽으면 다시 살립니다. 이것은 "호스트가
부팅될 때 자동 시작"이 아니라 상시 적용되는 규칙입니다. 플랫폼이 머신이 실행 중인지 계속 확인합니다.

`disks` — 어떤 디스크를 붙일지입니다. 위에서 기술한 `VMDisk` 객체를 이름으로 참조합니다.

```yaml
  cloudInit: |
    #cloud-config
    password: ubuntu
    packages: [ libguestfs-tools, virt-v2v, qemu-utils ]
    runcmd:
      - [ bash, -c, "wget ... mc && chmod +x /usr/local/bin/mc" ]
```

`cloudInit` — 머신이 첫 부팅 때 스스로 실행하는 지시입니다. 모든 클라우드 이미지의 표준 메커니즘으로,
시스템이 시작할 때 이런 텍스트를 찾아 실행합니다. vSphere에서 가장 가까운 것은 Customization
Specification인데, 다만 여기서는 텍스트로 표현되어 머신 자체와 같은 파일에 들어 있습니다.

여기서는 비밀번호를 설정하고, `virt-v2v`를 그 의존성과 함께 설치하며, `mc`를 내려받도록 요청합니다.
`mc`는 S3 스토리지를 다루는 콘솔 클라이언트로, 결과물을 버킷에 업로드할 때 쓸 바로 그 도구입니다.

⚠️ **평문 비밀번호** — 오직 학습용 테스트베드에서만 씁니다. 이 머신은 30분만 살아 있고 클러스터
내부에서만 접근할 수 있습니다. 실제 운영 머신에서는 `password` 대신 ssh 키를 넣습니다.
