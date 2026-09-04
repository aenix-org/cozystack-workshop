#!/bin/bash
# conversion-VM के अंदर VMware OVA -> qcow2 में कन्वर्ज़न।
# conversion-VM (ubuntu-20.04) में root के रूप में चलाएँ:  sudo bash convert.sh
set -euo pipefail

# =========================================================================
# अपने मान यहाँ पेस्ट करें।
#   क्रेडेंशियल डैशबोर्ड से लें: Bucket -> आपका बकेट -> Secrets टैब
#   (सीक्रेट bucket-<नाम>-app-credentials: accessKey / secretKey / bucketName)।
#   सोर्स OVA का लिंक ऑपरेटर देता है (इमेज वाला साझा बकेट)।
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # Secrets से endpoint फ़ील्ड, लेकिन https:// प्रीफ़िक्स के साथ
                                             # (डैशबोर्ड में स्कीम के बिना दिखता है, https:// खुद जोड़ें)
BUCKET="ВСТАВЬТЕ_bucketName"                 # आपके बकेट का bucketName
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # आपके बकेट का accessKey
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # आपके बकेट का secretKey
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # वर्कशॉप का तैयार demo-OVA (पहले से अपलोड किया हुआ; अपने से बदल सकते हैं)
# =========================================================================

echo "== 1. nested-virt? (अगर /dev/kvm नहीं है -> TCG, धीमा, पर काम करता है) =="
if [ -e /dev/kvm ]; then echo "  /dev/kvm मौजूद है — हार्डवेयर त्वरण"; else
  echo "  /dev/kvm नहीं है -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. सोर्स OVA डाउनलोड कर रहा हूँ =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (-of qcow2 फ़्लैग अनिवार्य है) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. परिणाम को अपने बकेट (S3) में अपलोड कर रहा हूँ =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. VM Disk के लिए लिंक बना रहा हूँ (presigned, 7 दिन तक वैध) =="
echo "   नीचे 'Share:' पंक्ति से URL कॉपी करें — यही http-import के लिए लिंक है।"
echo "   (लिंक अस्थायी और साइन किया हुआ है — बकेट तक anonymous-एक्सेस की ज़रूरत नहीं)"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== हो गया। ऊपर 'Share:' पंक्ति से URL कॉपी करें और उसे"
echo "   manifests/03-app-vm.yaml (url फ़ील्ड) में डालें, फिर kubectl apply -f।"
echo "   डैशबोर्ड से भी वही: VM Disk -> Deploy new -> source = http -> यह URL।"
