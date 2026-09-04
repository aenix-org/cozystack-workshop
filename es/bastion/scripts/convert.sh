#!/bin/bash
# Convertir VMware OVA -> qcow2 dentro de la conversion-VM.
# Ejecutar en la conversion-VM (ubuntu-20.04) como root:  sudo bash convert.sh
set -euo pipefail

# =========================================================================
# PEGUE SUS VALORES.
#   Las credenciales se obtienen en el dashboard: Bucket -> su bucket -> pestaña Secrets
#   (secreto bucket-<nombre>-app-credentials: accessKey / secretKey / bucketName).
#   El operador proporciona el enlace al OVA de origen (bucket compartido de imágenes).
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # campo endpoint de Secrets, pero CON el PREFIJO https://
                                             # (el dashboard lo muestra sin esquema, añada https:// usted mismo)
BUCKET="ВСТАВЬТЕ_bucketName"                 # bucketName de su bucket
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # accessKey de su bucket
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # secretKey de su bucket
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # demo-OVA del workshop listo (ya subido; puede reemplazarlo por el suyo)
# =========================================================================

echo "== 1. nested-virt? (si falta /dev/kvm -> TCG, más lento, pero funciona) =="
if [ -e /dev/kvm ]; then echo "  /dev/kvm presente — aceleración por hardware"; else
  echo "  /dev/kvm AUSENTE -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. descargando el OVA de origen =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (el flag -of qcow2 es obligatorio) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. subiendo el resultado a SU bucket (S3) =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. generando un enlace para el VM Disk (presigned, válido 7 días) =="
echo "   Copie la URL de la línea 'Share:' de abajo — ese es el enlace para el http-import."
echo "   (el enlace es temporal y firmado — NO se necesita acceso anónimo al bucket)"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== LISTO. Copie la URL de la línea 'Share:' de arriba y péguela en"
echo "   manifests/03-app-vm.yaml (el campo url), luego kubectl apply -f."
echo "   Lo mismo desde el dashboard: VM Disk -> Deploy new -> source = http -> esta URL."
