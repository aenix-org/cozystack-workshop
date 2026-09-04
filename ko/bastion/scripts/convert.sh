#!/bin/bash
# conversion-VM 내부에서 VMware OVA -> qcow2 변환.
# conversion-VM(ubuntu-20.04)에서 root 권한으로 실행:  sudo bash convert.sh
set -euo pipefail

# =========================================================================
# 여기에 값을 붙여넣으세요.
#   자격 증명은 대시보드에서 확인: Bucket -> 사용자 버킷 -> Secrets 탭
#   (시크릿 bucket-<이름>-app-credentials: accessKey / secretKey / bucketName).
#   원본 OVA 링크는 운영자가 제공합니다(이미지 공용 버킷).
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # Secrets의 endpoint 필드, 단 https:// 접두사 포함
                                             # (대시보드에는 스킴 없이 표시되므로 https://를 직접 추가하세요)
BUCKET="ВСТАВЬТЕ_bucketName"                 # 사용자 버킷의 bucketName
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # 사용자 버킷의 accessKey
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # 사용자 버킷의 secretKey
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # 준비된 워크숍 데모 OVA(이미 업로드됨; 직접 만든 것으로 교체 가능)
# =========================================================================

echo "== 1. nested-virt? (/dev/kvm가 없으면 -> TCG, 더 느리지만 동작함) =="
if [ -e /dev/kvm ]; then echo "  /dev/kvm 있음 — 하드웨어 가속"; else
  echo "  /dev/kvm 없음 -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. 원본 OVA 다운로드 중 =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (-of qcow2 플래그 필수) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. 결과를 사용자 버킷(S3)에 업로드 =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. VM Disk용 링크 생성 (presigned, 7일간 유효) =="
echo "   아래 'Share:' 줄의 URL을 복사하세요 — 이것이 http-import용 링크입니다."
echo "   (링크는 임시이며 서명되어 있음 — 버킷에 대한 anonymous 접근은 필요 없음)"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== 완료. 위 'Share:' 줄의 URL을 복사하여"
echo "   manifests/03-app-vm.yaml(url 필드)에 입력한 뒤 kubectl apply -f 실행."
echo "   대시보드로도 동일: VM Disk -> Deploy new -> source = http -> 이 URL."
