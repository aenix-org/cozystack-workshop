## 31. 무언가 동작하지 않을 때

**사람들이 흔히 걸려 넘어지는 것들의 짧은 목록**

• **애플리케이션에 외부에서 접근되지 않습니다.** 마이그레이션한 CentOS에서 흔한 원인은
  내장 방화벽입니다 — 8080 포트를 막고 있습니다:
  ```bash
  systemctl stop firewalld
  ```

• **`kubectl`이 "forbidden"이라고 답합니다.** 자신의 namespace로 요청하고 있는지 확인하세요:
  `-n tenant-workshopXX`. 그리고 `vm`이나 `vmi`가 아니라 `vminstance`가 사용 가능하다는 점을 기억하세요.

• **주문이 생성되지 않는데 health는 여전히 `200`을 반환합니다.** 테이블이 생성되지 않은 것입니다 —
  데이터베이스 스키마에 관한 메시지로 돌아가세요.

• **새 머신(app-VM)이 `Pending`에서 멈춰 있습니다.** 변환기 머신이 꺼지지 않은 것입니다 —
  그 머신이 쿼터 중 8Gi를 붙잡고 있어서 새 머신에 할당할 양이 부족합니다. 해당 머신과 그 디스크를 삭제하세요:
  ```bash
  kubectl delete vminstance convert --namespace tenant-workshopXX
  kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
  ```

• **이미지를 업로드할 때 `mc`가 `Insufficient permissions`라고 표시합니다.** `convert.sh`의
  `BUCKET` 필드에 실제 `bucketName`(긴 `bucket-...-...`) 대신 `my-images`가 들어가 있습니다.
  대시보드에서 버킷의 secret에 있는 `bucketName`을 가져와 넣으세요.

• **디스크가 Terminating 상태에서 멈춰 있습니다.** 디스크 크기가 이미지보다 작을 가능성이 큽니다.
  ubuntu-20.04에는 최소 25Gi가 필요합니다.

• **아무것도 도움이 되지 않습니다.** 여기에 적어 주시면 함께 해결하겠습니다. 이것은 부끄러워할 일이
  아니라 이 일의 정상적인 부분입니다 — 실제 마이그레이션에서도 똑같습니다, 다만 새벽 세 시일 뿐이죠.
