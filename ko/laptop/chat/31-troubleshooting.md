## 31. 무언가가 동작하지 않을 때

**사람들이 자주 걸려 넘어지는 것들의 짧은 목록**

• **애플리케이션에 외부에서 접근할 수 없습니다.** 마이그레이션한 CentOS에서 흔한 원인은
  내장 방화벽입니다 — 8080 포트를 막고 있습니다:
  ```bash
  systemctl stop firewalld
  ```

• **`kubectl`이 "forbidden"이라고 답합니다.** 자신의 namespace로 요청하고 있는지 확인하십시오:
  `-n tenant-workshopXX`. 그리고 `vm`이나 `vmi`가 아니라 `vminstance`를 사용할 수 있다는 점을 기억하십시오.

• **주문이 생성되지 않는데, 헬스 체크는 여전히 `200`을 반환합니다.** 테이블이 생성되지 않았습니다 —
  데이터베이스 스키마에 관한 메시지로 돌아가십시오.

• **새 머신(app-VM)이 `Pending` 상태에 멈춰 있습니다.** 변환기 머신이 꺼지지 않았습니다 —
  이 머신이 쿼터의 8Gi를 차지하고 있어서 새 머신에 할당할 자원이 부족합니다. 이 머신과 그 디스크를 삭제하십시오:
  ```bash
  kubectl delete vminstance convert --namespace tenant-workshopXX
  kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
  ```

• **이미지를 업로드할 때 `mc`가 `Insufficient permissions`라고 보고합니다.** `convert.sh`의
  `BUCKET` 필드에 실제 `bucketName`(긴 `bucket-...-...`) 대신 `my-images`가 들어 있습니다.
  대시보드의 버킷 secret에서 `bucketName`을 가져와 넣으십시오.

• **디스크가 Terminating 상태에 멈춰 있습니다.** 대개 디스크 크기가 이미지보다 작기 때문입니다.
  ubuntu-20.04의 경우 최소 25Gi가 필요합니다.

• **아무것도 도움이 되지 않습니다.** 여기에 적어 주시면 함께 해결하겠습니다. 이것은 업무의 정상적인 일부이며
  창피해할 일이 아닙니다 — 실제 마이그레이션에서도 마찬가지이고, 다만 새벽 3시에 벌어질 뿐입니다.
