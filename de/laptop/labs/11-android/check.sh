#!/usr/bin/env bash
# Prüfung für Lab 11: Der Android-Build lief bis zum Ende durch, und die APK erreichte den Bucket.
#
# Wir prüfen nicht "Job erstellt", sondern drei verschiedene Aussagen, und sie sind nicht gleichbedeutend:
#   1) der Job wurde erfolgreich abgeschlossen,
#   2) darin wurde tatsächlich eine APK gebaut (BUILD SUCCESSFUL),
#   3) die Datei gelangte tatsächlich in den Objektspeicher (der Marker APK-UPLOADED).
# Ein Job kann erfolgreich abschließen und nichts bauen — wenn jemand das Skript geändert hat.
#
# Läuft auf dem Laptop, aus dem Ordner dieses Labs, mit Zugriff auf den Schulungscluster `lab`
# (nicht auf den Tenant im Management-Cluster — der Build läuft im Cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# Das Skript ändert nichts im Cluster — es liest nur und sendet HTTP-Anfragen.
# Vor dem Aufräumen ausführen: mit dem Job werden auch seine Logs gelöscht, und ohne Logs
# gibt es nichts mehr, um zwei der drei obigen Aussagen zu bestätigen.

# Diese beiden Variablen greift lib.sh auf — sie landen im Kopf des Berichts und im
# Dateinamen report-<lab>-<datum>.md, den das Skript neben sich ablegt.
LAB_NAME="11-android"
LAB_TITLE="Lab 11 · Bau einer mobilen App im Cluster"
# Gemeinsame Prüfbibliothek: von hier kommen ok / fail / warn / evidence / finish,
# die Anfrage aus dem Cluster heraus und das Schreiben des Berichts. Der Pfad wird von dem Ort
# aus bestimmt, an dem das Skript selbst liegt, daher funktioniert der Start aus jedem Verzeichnis gleich.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Wir stoppen sofort, wenn KUBECONFIG nicht gesetzt ist. Ohne ihn sucht kubectl einen Cluster
# auf dem Laptop selbst, findet keinen und lässt alle Prüfungen nacheinander mit demselben Fehler scheitern,
# aus dem die wahre Ursache nicht ersichtlich ist.
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# Der Wert eines Secret-Schlüssels. base64 -d ist nicht überall gleich (BSD vs. GNU),
# daher dekodieren wir mit Python — es wird von der Prüfbibliothek ohnehin benötigt.
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- Secret mit Zugriff auf den Bucket -------------------------------------
# Wir prüfen nicht die Existenz des Secrets, sondern dass alle vier Felder darin ausgefüllt sind.
# Das Secret wird von Hand erstellt, mit vier --from-literal nacheinander, und das häufigste Problem ist
# ein leerer oder fehlender Wert: das Objekt wird dabei erfolgreich erstellt, aber der Build scheitert
# im letzten Schritt, wenn der Build bereits durchgelaufen ist. Billiger, es jetzt zu erfahren.
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "Secret ${SECRET} ist vorhanden, alle vier Schlüssel sind ausgefüllt"
    # Die Schlüsselwerte landen nicht im Bericht — nur die Feldnamen.
    evidence "Felder des Secrets ${SECRET}" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <verborgen>
secretKey: <verborgen>"
  else
    fail "im Secret ${SECRET} sind folgende Felder nicht ausgefüllt:${MISSING}" \
         "erstellen Sie das Secret mit dem Befehl aus der README neu, die Werte werden im Dashboard entnommen: Bucket -> builds -> Secrets"
  fi
else
  fail "im Cluster gibt es kein Secret ${SECRET}" \
       "erstellen Sie das Secret: kubectl create secret generic ${SECRET} --from-literal=endpoint=... (vier Felder)"
fi

# --- ist der Speicher aus dem Cluster heraus erreichbar --------------------
# Die häufigste Ursache für "der Job scheiterte im fünften Schritt" sind nicht die Schlüssel, sondern dass
# der Speicher aus dem Cluster nicht erreichbar ist. Wir prüfen das getrennt vom Build.
# Die Anfrage geht aus einem Pod, nicht vom Laptop: der Laptop hat sein eigenes Netz und seine eigenen Routen,
# und seine erfolgreiche Antwort würde nichts darüber aussagen, ob der Build dorthin durchkommt.
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # Bewusst ohne -k: der Build spricht mit dem Speicher unter Zertifikatsprüfung, und die Prüfung
  # muss an derselben Stelle scheitern, an der auch der Job scheitert, statt bei einem abgelaufenen Zertifikat grün zu melden.
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "Speicher ${EP} antwortet aus dem Cluster heraus (HTTP ${CODE})"
      evidence "Antwort des Speichers" "GET https://${EP}/ -> HTTP ${CODE}
Die Codes 403 und 404 sind hier normal: eine anonyme Anfrage an den S3-Root soll abgelehnt werden."
      ;;
    5*)
      warn "Speicher ${EP} antwortet mit Fehler HTTP ${CODE}" \
           "der Build kann durchlaufen, aber der APK-Upload nicht; sagen Sie dem Kursleiter Bescheid"
      ;;
    *)
      fail "Speicher ${EP} antwortet nicht aus dem Cluster heraus" \
           "prüfen Sie das Feld endpoint im Secret: es muss OHNE https:// und ohne Schrägstrich am Ende sein"
      ;;
  esac
else
  warn "Speicherverfügbarkeit wird nicht geprüft" \
       "zuerst wird das Secret ${SECRET} mit dem Feld endpoint benötigt"
fi

# --- der Job selbst --------------------------------------------------------
# Wir schauen auf .status.succeeded, nicht auf die bloße Existenz des Job: das Objekt wird
# sofort und immer erfolgreich erstellt, während der Erfolg der Aufgabe bedeutet, dass der Pod mit Code 0 endete.
# Der Zustand des Pods wird getrennt betrachtet, weil "läuft noch" und "hängt in Pending" für
# einen Menschen verschiedene Nachrichten sind: das erste bedeutet warten, das zweite, dass Warten sinnlos ist
# und der Knoten vergrößert werden muss.
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "im Cluster gibt es keinen Job ${JOB}" \
       "starten Sie den Build: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} wurde erfolgreich abgeschlossen"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
abgeschlossen: ${DURATION:-unbekannt}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "der Build-Pod hängt in Pending — er ist nicht gestartet und startet auch nicht von selbst" \
         "schauen Sie sich die Ursache an: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; bei Insufficient memory vergrößern Sie den Knoten auf u1.large — wie das geht, steht in der README"
    evidence "Ereignisse des Build-Pods" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} wurde mit einem Fehler abgeschlossen (fehlgeschlagene Versuche: ${FAILED})" \
         "schauen Sie sich die letzten Log-Zeilen an: kubectl logs job/${JOB} --tail=40"
    evidence "Ende des Logs des fehlgeschlagenen Builds" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} ist noch nicht abgeschlossen (Pod-Zustand: ${POD_PHASE:-unbekannt})" \
         "der erste Build dauert von ein paar Minuten bis zu einer Viertelstunde, je nach Verbindung; verfolgen Sie: kubectl logs -f job/${JOB}"
  fi

  # --- was genau ist darin passiert ---------------------------------------
  # Ein erfolgreicher Job allein beweist nichts außer einem Rückgabecode von null.
  # Deshalb öffnen wir das Log und suchen darin nach zwei verschiedenen Belegen: BUILD SUCCESSFUL —
  # dass die Kompilierung bis zum Ende lief, und die Markerzeile APK-UPLOADED, die das Skript
  # nur nach dem Kopieren der Datei in den Bucket ausgibt. Das zweite ist stärker als das erste: eine APK kann gebaut werden
  # und im Pod liegen bleiben, der gleich verschwindet.
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "Build-Logs sind nicht verfügbar" \
         "der Build-Pod ist gelöscht oder noch nicht erstellt; ohne Logs lässt sich nicht bestätigen, dass die APK tatsächlich gebaut wurde"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "die APK wurde tatsächlich gebaut (${GRADLE_LINE})"
    else
      fail "im Log fehlt die Zeile BUILD SUCCESSFUL — die Kompilierung lief nicht bis zum Ende" \
           "suchen Sie die erste Zeile mit FAILURE: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "die APK gelangte in den Bucket: ${UPLOADED}"
      evidence "Bucket-Inhalt nach dem Build" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 lade das APK in den Bucket/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "die APK wurde gebaut, gelangte aber nicht in den Bucket" \
           "schauen Sie sich das Ende des Logs an: kubectl logs job/${JOB} --tail=20; meist ist bucketName schuld — es braucht den langen Namen aus dem Dashboard, nicht 'builds'"
    fi
  fi
fi

# --- hat der Knoten genug Platz für einen solchen Build --------------------
# Kein Urteil, sondern eine Erklärung: wenn der Job nicht gepasst hat, liegt die Ursache fast immer hier.
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "der größte Knoten stellt ${BIGGEST_H} Speicher bereit — für den Build ausreichend"
      else
        warn "der größte Knoten stellt nur ${BIGGEST_H} Speicher bereit" \
             "der Build fordert allein für requests 4Gi; wenn der Job in Pending hängt, vergrößern Sie den Knotentyp auf u1.large — wie, steht in der README"
      fi
      ;;
    *)
      warn "die Knoten haben weniger als ein Gigabyte verfügbaren Speicher (${BIGGEST_H})" \
           "ein Android-Build passt dort nicht hinein, vergrößern Sie den Knotentyp — wie, steht in der README"
      ;;
  esac
  evidence "Knotenressourcen" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
