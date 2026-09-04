#!/bin/bash
# 在 conversion-VM 内部将 VMware OVA -> qcow2 进行转换。
# 在 conversion-VM (ubuntu-20.04) 中以 root 身份运行：sudo bash convert.sh
set -euo pipefail

# =========================================================================
# 填入你的取值。
#   凭据在仪表盘中获取：Bucket -> 你的 bucket -> Secrets 标签页
#   （密钥 bucket-<名称>-app-credentials：accessKey / secretKey / bucketName）。
#   源 OVA 的链接由运营方提供（共享的镜像 bucket）。
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # Secrets 中的 endpoint 字段，但要带上 https:// 前缀
                                             # （仪表盘中不带协议头显示，请自行加上 https://）
BUCKET="ВСТАВЬТЕ_bucketName"                 # 你的 bucket 的 bucketName
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # 你的 bucket 的 accessKey
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # 你的 bucket 的 secretKey
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # 工作坊现成的演示 OVA（已上传；可替换为你自己的）
# =========================================================================

echo "== 1. nested-virt? (如果没有 /dev/kvm -> TCG，较慢，但可用) =="
if [ -e /dev/kvm ]; then echo "  存在 /dev/kvm — 硬件加速"; else
  echo "  没有 /dev/kvm -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. 正在下载源 OVA =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (-of qcow2 标志是必需的) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. 正在把结果上传到你自己的 bucket (S3) =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. 正在为 VM Disk 生成链接 (presigned，有效期 7 天) =="
echo "   从下面的 'Share:' 行复制 URL — 这就是用于 http-import 的链接。"
echo "   （该链接是临时且已签名的 — 不需要对 bucket 的匿名访问）"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== 完成。从上面的 'Share:' 行复制 URL，并填入"
echo "   manifests/03-app-vm.yaml (url 字段)，然后 kubectl apply -f。"
echo "   通过仪表盘操作相同：VM Disk -> Deploy new -> source = http -> 此 URL。"
