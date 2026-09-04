#!/bin/bash
# conversion-VM 内で VMware OVA を qcow2 に変換します。
# conversion-VM (ubuntu-20.04) 上で root として実行:  sudo bash convert.sh
set -euo pipefail

# =========================================================================
# あなたの値を貼り付けてください。
#   認証情報はダッシュボードから取得します: Bucket -> あなたのバケット -> Secrets タブ
#   (シークレット bucket-<名前>-app-credentials: accessKey / secretKey / bucketName)。
#   ソース OVA へのリンクはオペレーターが提供します(共有イメージバケット)。
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # Secrets の endpoint フィールド。ただし https:// プレフィックス付きで
                                             # (ダッシュボードではスキームなしで表示されるので、https:// は自分で追加してください)
BUCKET="ВСТАВЬТЕ_bucketName"                 # あなたのバケットの bucketName
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # あなたのバケットの accessKey
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # あなたのバケットの secretKey
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # 既製のワークショップ demo-OVA(アップロード済み。自分のものに差し替え可)
# =========================================================================

echo "== 1. nested-virt? (/dev/kvm がない場合 -> TCG、遅いが動作します) =="
if [ -e /dev/kvm ]; then echo "  /dev/kvm あり — ハードウェアアクセラレーション"; else
  echo "  /dev/kvm なし -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. ソース OVA をダウンロード中 =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (-of qcow2 フラグは必須) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. 結果を自分のバケット(S3)にアップロード中 =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. VM Disk 用のリンクを生成中(presigned、7 日間有効) =="
echo "   下の 'Share:' 行の URL をコピーしてください — これが http-import 用のリンクです。"
echo "   (リンクは一時的で署名付きです — バケットへの anonymous アクセスは不要です)"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== 完了。上の 'Share:' 行の URL をコピーして"
echo "   manifests/03-app-vm.yaml(url フィールド)に貼り付け、kubectl apply -f を実行してください。"
echo "   ダッシュボードでも同じことができます: VM Disk -> Deploy new -> source = http -> この URL。"
