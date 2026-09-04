#!/bin/bash
# Konvertierung VMware OVA -> qcow2 innerhalb der conversion-VM.
# In der conversion-VM (ubuntu-20.04) als root ausführen:  sudo bash convert.sh
set -euo pipefail

# =========================================================================
# FÜGEN SIE IHRE WERTE EIN.
#   Die Zugangsdaten stammen aus dem Dashboard: Bucket -> Ihr Bucket -> Reiter Secrets
#   (Secret bucket-<name>-app-credentials: accessKey / secretKey / bucketName).
#   Den Link zur Quell-OVA stellt der Operator bereit (gemeinsamer Image-Bucket).
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # Feld endpoint aus Secrets, aber MIT dem Präfix https://
                                             # (im Dashboard ohne Schema angezeigt, https:// selbst hinzufügen)
BUCKET="ВСТАВЬТЕ_bucketName"                 # bucketName Ihres Buckets
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # accessKey Ihres Buckets
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # secretKey Ihres Buckets
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # fertige Workshop-Demo-OVA (bereits hochgeladen; kann durch Ihre eigene ersetzt werden)
# =========================================================================

echo "== 1. nested-virt? (wenn /dev/kvm fehlt -> TCG, langsamer, aber funktioniert) =="
if [ -e /dev/kvm ]; then echo "  /dev/kvm vorhanden — Hardware-Beschleunigung"; else
  echo "  /dev/kvm FEHLT -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. lade die Quell-OVA herunter =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (das Flag -of qcow2 ist erforderlich) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. lade das Ergebnis in IHREN Bucket hoch (S3) =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. erzeuge einen Link für die VM Disk (presigned, 7 Tage gültig) =="
echo "   Kopieren Sie die URL aus der Zeile 'Share:' unten — das ist der Link für den http-Import."
echo "   (der Link ist temporär und signiert — anonymer Zugriff auf den Bucket ist NICHT nötig)"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== FERTIG. Kopieren Sie die URL aus der Zeile 'Share:' oben und tragen Sie sie in"
echo "   manifests/03-app-vm.yaml ein (Feld url), dann kubectl apply -f."
echo "   Dasselbe über das Dashboard: VM Disk -> Deploy new -> source = http -> diese URL."
