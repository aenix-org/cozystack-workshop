#!/bin/bash
# 在 conversion-VM 内将 VMware OVA 转换为 qcow2。
# 在 conversion-VM (ubuntu-20.04) 中以 root 身份运行：sudo bash convert.sh
set -euo pipefail

# =========================================================================
# 填入你的值。
#   凭据从仪表盘获取：Bucket -> 你的 bucket -> Secrets 标签页
#   （secret bucket-<名称>-app-credentials：accessKey / secretKey / bucketName）。
#   源 OVA 的链接由操作员提供（共享的镜像 bucket）。
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # Secrets 中的 endpoint 字段，但要带上 https:// 前缀
                                             # （仪表盘显示时不含协议头，请自行加上 https://）
BUCKET="ВСТАВЬТЕ_bucketName"                 # 你的 bucket 的 bucketName
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # 你的 bucket 的 accessKey
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # 你的 bucket 的 secretKey
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # 现成的 workshop demo-OVA（已上传；可替换为你自己的）
# =========================================================================

echo "== 1. nested-virt? (若 /dev/kvm 不存在 -> TCG，较慢，但可用) =="
if [ -e /dev/kvm ]; then echo "  /dev/kvm 存在 — 硬件加速"; else
  echo "  /dev/kvm 不存在 -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. 正在下载源 OVA =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (必须带 -of qcow2 标志) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. 正在把结果上传到你自己的 bucket (S3) =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. 正在为 VM Disk 生成链接 (presigned，有效期 7 天) =="
echo "   从下方 'Share:' 行复制 URL — 这就是用于 http-import 的链接。"
echo "   （链接是临时且已签名的 — 不需要对 bucket 的匿名访问）"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== 完成。从上方 'Share:' 行复制 URL 并填入"
echo "   manifests/03-app-vm.yaml (url 字段)，然后 kubectl apply -f。"
echo "   通过仪表盘操作相同：VM Disk -> Deploy new -> source = http -> 此 URL。"
