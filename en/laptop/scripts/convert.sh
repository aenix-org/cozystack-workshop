#!/bin/bash
# Convert VMware OVA -> qcow2 inside the conversion-VM.
# Run in the conversion-VM (ubuntu-20.04) as root:  sudo bash convert.sh
set -euo pipefail

# =========================================================================
# PASTE YOUR VALUES.
#   Credentials come from the dashboard: Bucket -> your bucket -> Secrets tab
#   (secret bucket-<name>-app-credentials: accessKey / secretKey / bucketName).
#   The link to the source OVA is provided by the operator (shared image bucket).
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # endpoint field from Secrets, but WITH THE https:// PREFIX
                                             # (shown without the scheme in the dashboard, add https:// yourself)
BUCKET="ВСТАВЬТЕ_bucketName"                 # bucketName of your bucket
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # accessKey of your bucket
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # secretKey of your bucket
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # ready-made demo OVA for the workshop (already uploaded; you can replace it with your own)
# =========================================================================

echo "== 1. nested-virt? (if /dev/kvm is missing -> TCG, slower, but works) =="
if [ -e /dev/kvm ]; then echo "  /dev/kvm present — hardware acceleration"; else
  echo "  /dev/kvm MISSING -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. downloading the source OVA =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (the -of qcow2 flag is mandatory) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. uploading the result to YOUR bucket (S3) =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. generating a link for the VM Disk (presigned, valid for 7 days) =="
echo "   Copy the URL from the 'Share:' line below — that is the link for http-import."
echo "   (the link is temporary and signed — anonymous access to the bucket is NOT required)"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== DONE. Copy the URL from the 'Share:' line above and put it into"
echo "   manifests/03-app-vm.yaml (the url field), then kubectl apply -f."
echo "   The same via the dashboard: VM Disk -> Deploy new -> source = http -> this URL."
