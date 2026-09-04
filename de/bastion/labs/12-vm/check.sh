#!/usr/bin/env bash
# Prüfung für Lab 12: Die migrierte virtuelle Maschine ist nach außen über den Ingress und
# die Domain der Plattform veröffentlicht — genau wie die containerisierte Anwendung.
#
# Wir prüfen nicht "Objekte erstellt", sondern die tatsächliche, inhaltliche Funktion:
#   1) der Domainname des Tenants liefert HTTP 200 und es ist die Verzeichnis-Seite,
#   2) die virtuelle Maschine selbst läuft (Ready),
#   3) der Ingress, der die Maschine veröffentlicht, ist vorhanden.
# Der erste Punkt ist der wichtigste: Er ist der Beweis, dass das Verzeichnis von außen sichtbar ist.
#
# Läuft auf der VM, aus dem Ordner dieses Labs. Erfordert Tenant-Zugang und die Tenant-Nummer:
#     export KUBECONFIG=~/.kube/config
#     export COZY_TENANT=workshopXX
#     cd labs/12-vm && ./check.sh
# Die Domain-Prüfung funktioniert auch ohne Tenant-Zugang — dafür genügt curl. Ohne Tenant-
# Zugang fällt das Skript nicht aus: Es überspringt die tenantseitigen Prüfungen und sagt das.
#
# Das Skript ändert nichts — es liest nur und sendet HTTP-Anfragen. Vor der Aufräumphase ausführen:
# ist die Maschine erst gelöscht, gibt es nichts mehr zu prüfen.

# Diese beiden Variablen greift lib.sh ab — sie landen im Kopf des Berichts und im
# Namen der Datei report-<lab>-<datum>.md, die das Skript neben sich ablegt.
LAB_NAME="12-vm"
LAB_TITLE="Lab 12 · Eine virtuelle Maschine neben Containern"
# Gemeinsame Prüfbibliothek: ok / fail / warn / evidence / finish kommen von hier.
# Der Pfad wird relativ zum Ort aufgelöst, an dem das Skript selbst liegt, sodass der Start aus
# jedem Verzeichnis gleich funktioniert.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Die Tenant-Nummer ist zwingend: Aus ihr werden sowohl der Namespace-Name als auch der Domainname
# gebildet, unter dem das Verzeichnis veröffentlicht ist. Ohne sie gibt es nichts zu prüfen.
need_tenant

# Die Namen, die wir prüfen. VM ist der Name der BESTELLUNG der Maschine, d. h. des VMInstance-Objekts;
# `kubectl get vminstance` wird damit abgefragt. Die tatsächlich laufende Instanz heißt
# anders: Die Plattform stellt die Bestellung mit dem Chart `vm-instance` bereit, der Chart-Name
# wird mit dem Release-Namen verklebt, und man erhält vm-instance-spravochnik.
VM=spravochnik
NS="tenant-${COZY_TENANT}"
# Die Domain, auf der der Moderator das Verzeichnis vorab über Ingress veröffentlicht hat. Dieselbe
# Adresse öffnen Sie im Browser.
HOST="spravochnik.${COZY_TENANT}.workshop.aenix.io"
URL="http://${HOST}"

# Tenant-Zugang ist nicht zwingend: Die Domain wird mit einem einfachen curl geprüft. Wenn KUBECONFIG
# gesetzt ist und der Tenant antwortet — fügen wir Prüfungen für den Maschinenzustand und Ingress hinzu.
TENANT_OK=0
if [ -n "${KUBECONFIG:-}" ] && kubectl -n "$NS" get vminstance >/dev/null 2>&1; then
  TENANT_OK=1
fi

# --- das Wichtigste: das Verzeichnis ist von außen über die Domain sichtbar ---------
# Wir holen den Antwortcode und den Body getrennt: Der Code unterscheidet "noch niemand hinter
# dem Ingress" (503) von "zeigt an die falsche Stelle" (404) und "gar keine Domain" (000),
# während der Body bestätigt, dass es das Verzeichnis ist, das antwortet, und kein zufälliger Platzhalter.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)"
BODY="$(curl -s --max-time 10 "$URL" 2>/dev/null)"

case "$CODE" in
  200)
    case "$BODY" in
      *"Справочник сотрудников"*)
        ok "Verzeichnis veröffentlicht: ${URL} antwortet mit 200 und liefert die Verzeichnis-Seite"
        evidence "Antwort über die Domain" "Anfrage: ${URL}
Antwortcode: ${CODE}
$(printf '%s' "$BODY" | head -3)"
        ;;
      *)
        fail "${URL} liefert 200, aber dies ist nicht die Verzeichnis-Seite" \
             "hinter der Domain antwortet etwas anderes; prüfen Sie, dass auf Port 8080 innerhalb der Maschine genau das Verzeichnis lauscht"
        ;;
    esac
    ;;
  503)
    fail "Domain ${URL} antwortet mit 503 — hinter dem Ingress ist noch niemand, der antwortet" \
         "die Maschine bootet noch oder der Verzeichnis-Dienst auf 8080 ist nicht hochgekommen; warten Sie auf Ready bei der vminstance und schauen Sie in die Maschinenkonsole"
    ;;
  000)
    fail "Domain ${URL} antwortet überhaupt nicht" \
         "prüfen Sie das Netzwerk; den Ingress mit diesem Host erstellt der Moderator — wenn es gar keine Domain gibt, fragen Sie ihn"
    ;;
  *)
    fail "Domain ${URL} antwortet mit ${CODE}, nicht mit 200" \
         "404 bedeutet, dass der Ingress auf den falschen Service zeigt; 5xx bedeutet, dass das Backend nicht bereit ist zu antworten"
    ;;
esac

# --- Tenant-Seite: die Maschine selbst und ihre Veröffentlichung --------------------
if [ "$TENANT_OK" -eq 0 ]; then
  warn "tenantseitige Prüfungen übersprungen: Tenant über KUBECONFIG nicht erreichbar" \
       "geben Sie Tenant-Zugang an: export KUBECONFIG=~/.kube/config"
else
  # Wir fragen nicht "existiert das Objekt", sondern die Ready-Bedingung: Die Maschinen-Bestellung wird
  # in einer Sekunde erstellt, aber der Gast kommt in drei bis fünf Minuten hoch, und die ganze Zeit
  # existiert die Maschine, aber das Verzeichnis antwortet noch nicht.
  if ! kubectl -n "$NS" get vminstance "$VM" >/dev/null 2>&1; then
    fail "im Tenant ${NS} gibt es keine virtuelle Maschine ${VM}" \
         "erstellen Sie einen VM Disk und eine VM Instance im Dashboard oder wenden Sie staff-directory-vm.yaml an"
  else
    VM_READY="$(kubectl -n "$NS" get vminstance "$VM" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [ "$VM_READY" = "True" ]; then
      ok "virtuelle Maschine ${VM} läuft"
    elif [ -n "$VM_READY" ]; then
      fail "virtuelle Maschine ${VM} existiert, ist aber nicht bereit (Ready=${VM_READY})" \
           "schauen Sie sich die Maschinenkarte im Dashboard an; das erste Einschalten dauert 3-5 Minuten"
    else
      warn "virtuelle Maschine ${VM} existiert, aber ihr Zustand konnte nicht gelesen werden" \
           "schauen Sie sie sich im Dashboard an: sie sollte eingeschaltet sein"
    fi
    evidence "Virtuelle Maschinen des Tenants" "$(kubectl -n "$NS" get vminstance 2>/dev/null)"
  fi

  # Den Ingress erstellt der Moderator, nicht der Teilnehmer. Wenn die Domain bereits mit 200
  # antwortet — ist er vorhanden; wir prüfen ihn separat, damit bei 503/404 sofort klar ist,
  # ob es überhaupt eine Veröffentlichung gibt.
  if kubectl -n "$NS" get ingress spravochnik >/dev/null 2>&1; then
    ok "Ingress spravochnik ist vorhanden — das Verzeichnis ist im Tenant veröffentlicht"
    evidence "Ingress des Tenants" "$(kubectl -n "$NS" get ingress spravochnik 2>/dev/null)"
  else
    warn "Ingress spravochnik im Tenant ${NS} nicht gefunden" \
         "ihn erstellt der Moderator; wenn die Domain bereits mit 200 antwortet, gibt es keinen Grund zur Sorge, andernfalls wenden Sie sich an den Moderator"
  fi
fi

finish
