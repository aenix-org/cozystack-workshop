#!/usr/bin/env bash
# Prüfung von Lab 12: Die migrierte VM ist über den Ingress und die Domain der
# Plattform nach außen veröffentlicht — genauso wie die containerisierte Anwendung.
#
# Wir prüfen nicht «Objekte angelegt», sondern dass die Sache tatsächlich funktioniert:
#   1) der Domainname des Tenants liefert HTTP 200 und es ist die Verzeichnis-Seite,
#   2) die virtuelle Maschine selbst läuft (Ready),
#   3) der Ingress, der die Maschine veröffentlicht, ist vorhanden.
# Der erste Punkt ist der wichtigste: er ist der Beweis, dass das Verzeichnis von außen sichtbar ist.
#
# Läuft auf dem Laptop, aus dem Ordner dieses Labs. Braucht Tenant-Zugang und die Tenant-Nummer:
#     export KUBECONFIG=~/.kube/workshop
#     export COZY_TENANT=workshopXX
#     cd labs/12-vm && ./check.sh
# Die Domain-Prüfung funktioniert auch ohne Tenant-Zugang — curl genügt ihr. Ohne Tenant-
# Zugang scheitert das Skript nicht: es überspringt die tenantseitigen Prüfungen und sagt das.
#
# Das Skript ändert nichts — es liest nur und sendet HTTP-Anfragen. Führe es vor dem Aufräumen aus:
# sobald die Maschine gelöscht ist, gibt es nichts mehr zu prüfen.

# Diese beiden Variablen werden von lib.sh aufgegriffen — sie gehen in den Kopf des Berichts und in den
# Dateinamen report-<lab>-<datum>.md, den das Skript neben sich ablegt.
LAB_NAME="12-vm"
LAB_TITLE="Lab 12 · Eine virtuelle Maschine neben den Containern"
# Gemeinsame Prüfbibliothek: ok / fail / warn / evidence / finish kommen von hier.
# Der Pfad wird relativ zu dem Ort aufgelöst, an dem das Skript selbst liegt, daher funktioniert
# der Start aus jedem Verzeichnis gleich.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Die Tenant-Nummer ist erforderlich: aus ihr entstehen sowohl der Namespace-Name als auch der
# Domainname, unter dem das Verzeichnis veröffentlicht ist. Ohne sie gibt es nichts zu prüfen.
need_tenant

# Die Namen, die wir prüfen. VM ist der Name der BESTELLUNG für eine Maschine, also des VMInstance-
# Objekts; danach wird `kubectl get vminstance` gefragt. Die tatsächlich laufende Instanz heißt
# anders: die Plattform rollt die Bestellung mit dem Chart `vm-instance` aus, der Chart-Name wird
# mit dem Release-Namen zusammengeklebt, und heraus kommt vm-instance-spravochnik.
VM=spravochnik
NS="tenant-${COZY_TENANT}"
# Die Domain, unter der der Moderator das Verzeichnis vorab über Ingress veröffentlicht hat. Dieselbe
# Adresse, die du im Browser öffnest.
HOST="spravochnik.${COZY_TENANT}.workshop.aenix.io"
URL="http://${HOST}"

# Tenant-Zugang ist nicht erforderlich: die Domain wird mit einem gewöhnlichen curl geprüft. Wenn
# KUBECONFIG gesetzt ist und der Tenant antwortet — fügen wir Prüfungen des Maschinenzustands und des Ingress hinzu.
TENANT_OK=0
if [ -n "${KUBECONFIG:-}" ] && kubectl -n "$NS" get vminstance >/dev/null 2>&1; then
  TENANT_OK=1
fi

# --- die Hauptsache: das Verzeichnis ist von außen über die Domain sichtbar -------------
# Wir nehmen den Antwortcode und den Body getrennt: der Code unterscheidet «hinter dem Ingress ist
# noch niemand» (503) von «führt an die falsche Stelle» (404) und «gar keine Domain» (000),
# und der Body bestätigt, dass genau das Verzeichnis antwortet, nicht irgendein zufälliger Platzhalter.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)"
BODY="$(curl -s --max-time 10 "$URL" 2>/dev/null)"

case "$CODE" in
  200)
    case "$BODY" in
      *"Mitarbeiterverzeichnis"*)
        ok "Verzeichnis veröffentlicht: ${URL} antwortet mit 200 und liefert die Verzeichnis-Seite"
        evidence "Antwort über die Domain" "Anfrage: ${URL}
Antwortcode: ${CODE}
$(printf '%s' "$BODY" | head -3)"
        ;;
      *)
        fail "${URL} liefert 200, aber es ist nicht die Verzeichnis-Seite" \
             "hinter der Domain antwortet etwas anderes; prüfe, dass genau das Verzeichnis auf Port 8080 innerhalb der Maschine lauscht"
        ;;
    esac
    ;;
  503)
    fail "Domain ${URL} antwortet mit 503 — hinter dem Ingress ist noch niemand, der antwortet" \
         "die Maschine bootet noch oder der Verzeichnisdienst auf 8080 ist nicht hochgekommen; warte, bis die vminstance Ready ist, und schau in die Konsole der Maschine"
    ;;
  000)
    fail "Domain ${URL} antwortet überhaupt nicht" \
         "prüfe das Netzwerk; den Ingress mit diesem Host legt der Moderator an — wenn es gar keine Domain gibt, frag ihn"
    ;;
  *)
    fail "Domain ${URL} antwortet mit ${CODE}, nicht mit 200" \
         "404 bedeutet, dass der Ingress zum falschen Service führt; 5xx bedeutet, dass das Backend nicht bereit ist zu antworten"
    ;;
esac

# --- Tenant-Seite: die Maschine selbst und ihre Veröffentlichung --------------------------
if [ "$TENANT_OK" -eq 0 ]; then
  warn "tenantseitige Prüfungen übersprungen: der Tenant ist über KUBECONFIG nicht erreichbar" \
       "gib Tenant-Zugang an: export KUBECONFIG=~/.kube/workshop"
else
  # Wir fragen nicht «existiert das Objekt», sondern nach der Ready-Bedingung: die Bestellung für eine
  # Maschine wird in einer Sekunde angelegt, während der Gast drei bis fünf Minuten hochkommt, und die
  # ganze Zeit existiert die Maschine, aber das Verzeichnis antwortet noch nicht.
  if ! kubectl -n "$NS" get vminstance "$VM" >/dev/null 2>&1; then
    fail "im Tenant ${NS} gibt es keine virtuelle Maschine ${VM}" \
         "lege eine VM Disk und eine VM Instance im Dashboard an oder wende staff-directory-vm.yaml an"
  else
    VM_READY="$(kubectl -n "$NS" get vminstance "$VM" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [ "$VM_READY" = "True" ]; then
      ok "virtuelle Maschine ${VM} läuft"
    elif [ -n "$VM_READY" ]; then
      fail "virtuelle Maschine ${VM} existiert, ist aber nicht bereit (Ready=${VM_READY})" \
           "schau dir die Maschinenkarte im Dashboard an; der erste Start dauert 3-5 Minuten"
    else
      warn "virtuelle Maschine ${VM} existiert, aber ihr Zustand konnte nicht gelesen werden" \
           "schau sie dir mit eigenen Augen im Dashboard an: sie sollte eingeschaltet sein"
    fi
    evidence "Virtuelle Maschinen des Tenants" "$(kubectl -n "$NS" get vminstance 2>/dev/null)"
  fi

  # Den Ingress legt der Moderator an, nicht der Teilnehmer. Wenn die Domain bereits mit 200 antwortet —
  # ist er vorhanden; wir prüfen separat, damit bei 503/404 sofort klar ist, ob es überhaupt eine
  # Veröffentlichung gibt.
  if kubectl -n "$NS" get ingress spravochnik >/dev/null 2>&1; then
    ok "Ingress spravochnik ist vorhanden — das Verzeichnis ist im Tenant veröffentlicht"
    evidence "Ingress des Tenants" "$(kubectl -n "$NS" get ingress spravochnik 2>/dev/null)"
  else
    warn "Ingress spravochnik im Tenant ${NS} nicht gefunden" \
         "ihn legt der Moderator an; wenn die Domain bereits mit 200 antwortet — kein Grund zur Sorge, andernfalls wende dich an den Moderator"
  fi
fi

finish
