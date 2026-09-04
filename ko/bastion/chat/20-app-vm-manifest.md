## 20. 자세히 살펴보기: 03-app-vm.yaml 안에는 무엇이 들어 있나

이번에도 객체는 두 개입니다 — 디스크와 머신.

```yaml
kind: VMDisk
spec:
  source:
    http:
      url: "ВСТАВЬТЕ_PRESIGNED_URL"
  storage: 10Gi
```

`source.image` 대신 `source.http` — 이전 단계와 다른 점은 이것뿐입니다. 여기에는 `convert.sh` 출력에서 나온 링크, 즉 `Share:`라는 단어 뒤에 오는 링크를 붙여넣습니다. 물음표 뒤의 긴 "꼬리"까지 포함해서 통째로 붙여넣어야 합니다. 이 꼬리가 바로 서명이며, 이것이 없으면 플랫폼은 접근을 거부당합니다.

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
  instanceProfile: centos.7
  disks:
    - name: app-1
```

`instanceProfile: centos.7` — 오래된 시스템을 위한 가상 하드웨어 프로필입니다. 보기보다 중요합니다. CentOS 7의 커널은 2016년 것이라서 최신 가상 하드웨어 설정 중 일부를 이해하지 못합니다. 이 프로필은 그런 커널이 다룰 수 있는 설정을 골라 줍니다.

이것은 그나저나 "오래된 시스템도 과연 돌아갈까"라는 질문에 대한 일반적인 답이기도 합니다. 돌아갑니다 — 시스템이 오래됐다고 플랫폼에 알려 주기만 하면.
