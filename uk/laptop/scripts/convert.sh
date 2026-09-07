#!/bin/bash
# Конвертація VMware OVA -> qcow2 всередині conversion-VM.
# Запускати в conversion-VM (ubuntu-20.04) під root:  sudo bash convert.sh
set -euo pipefail

# =========================================================================
# ВСТАВТЕ СВОЇ ЗНАЧЕННЯ.
#   Облікові дані беруться в дашборді: Bucket -> ваш бакет -> вкладка Secrets
#   (секрет bucket-<ім'я>-app-credentials: accessKey / secretKey / bucketName).
#   Посилання на вихідний OVA дає оператор (спільний бакет із образами).
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # поле endpoint із Secrets, але З ПРЕФІКСОМ https://
                                             # (у дашборді показано без схеми, додайте https:// самі)
BUCKET="ВСТАВЬТЕ_bucketName"                 # bucketName вашого бакета
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # accessKey вашого бакета
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # secretKey вашого бакета
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # готовий demo-OVA воркшопу (уже залитий; можна замінити своїм)
# =========================================================================

echo "== 1. nested-virt? (якщо /dev/kvm немає -> TCG, повільніше, але працює) =="
if [ -e /dev/kvm ]; then echo "  /dev/kvm є — апаратне прискорення"; else
  echo "  /dev/kvm НЕМАЄ -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. завантажую вихідний OVA =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (прапорець -of qcow2 обов'язковий) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. заливаю результат у СВІЙ бакет (S3) =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. генерую посилання для VM Disk (presigned, діє 7 днів) =="
echo "   Скопіюйте URL із рядка 'Share:' нижче — це і є посилання для http-import."
echo "   (посилання тимчасове та підписане — anonymous-доступ до бакета НЕ потрібен)"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== ГОТОВО. Скопіюйте URL із рядка 'Share:' вище і впишіть його в"
echo "   manifests/03-app-vm.yaml (поле url), потім kubectl apply -f."
echo "   Через дашборд те саме: VM Disk -> Deploy new -> source = http -> цей URL."
