#!/usr/bin/env bash
# Prüfung von Lab 0: Der Schulungscluster läuft und Sie sind mit ihm verbunden.
#
# Wir prüfen nicht, ob „ein Objekt erstellt wurde", sondern ob der Cluster inhaltlich funktioniert:
#   1) der Cluster lab antwortet über Ihre Zugangsdatei (KUBECONFIG=~/lab.kubeconfig),
#   2) mindestens ein Knoten ist im Zustand Ready,
#   3) auf den Knoten stehen freie Ressourcen für künftige Anwendungen bereit.
# Wenn COZY_TENANT gesetzt ist — schauen wir zusätzlich auf dem VERWALTUNGS-Cluster nach, ob die
# Bestellung Kubernetes/lab Ready erreicht hat und ob die Metrik-Erfassung aktiviert ist (ohne sie ist Lab 14 leer).
#
# Wird auf der VM ausgeführt, aus dem Ordner dieses Labs:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # für Prüfungen von der Tenant-Seite (optional)
#     cd labs/00-cluster && ./check.sh
#
# Das Skript liest nur — es ändert den Zustand des Clusters nicht.
LAB_NAME="00-cluster"
LAB_TITLE="Lab 0 · Ihr eigener Kubernetes-Cluster"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne Zugriff auf den Cluster lab selbst gibt es nichts zu prüfen — das ist der Hauptbeweis
# des Labs. need_kubeconfig stoppt das Skript mit einem verständlichen Hinweis,
# falls KUBECONFIG nicht gesetzt ist oder der Cluster nicht antwortet.
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) Verbindung zum Cluster lab -------------------------------------------
# need_kubeconfig hat bereits bestätigt, dass der Server antwortet. Wir halten das als
# separates Ergebnis fest und legen die Serverversion in den Bericht.
KVER="$(server_version)"
ok "der Cluster lab antwortet — die Zugangsdatei funktioniert"
[ -n "$KVER" ] && evidence "Serverversion des Clusters lab" "$KVER"

# --- 2) Knoten im Dienst -----------------------------------------------------
# Wir zählen, wie viele Knoten im Zustand Ready sind. Eine leere Liste bedeutet, dass der Cluster
# hochgefahren ist, aber die Knotengruppe md0 sich noch bereitstellt.
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "Knoten im Dienst: ${READY_NODES} von ${TOTAL_NODES} im Zustand Ready"
  [ -n "$NODES_WIDE" ] && evidence "Cluster-Knoten" "$NODES_WIDE"
else
  fail "kein Knoten ist im Zustand Ready (Knoten insgesamt: ${TOTAL_NODES:-0})" \
       "warten Sie ein paar Minuten, bis sich die Knotengruppe md0 bereitstellt; der Status steht im Dashboard der Anwendung lab, oder: kubectl get nodes"
  evidence "Cluster-Knoten" "${NODES_WIDE:-keine Knoten}"
fi

# --- 3) Gibt es Platz für künftige Anwendungen ------------------------------
# allocatable des ersten Knotens: Wenn es keine Ressourcen gibt, läuft nichts Weiteres.
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "auf den Knoten stehen Ressourcen für Anwendungen bereit (auf dem Knoten: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "Freie Knotenressourcen (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "die freien Knotenressourcen konnten nicht gelesen werden" \
       "das ist normalerweise vorübergehend — versuchen Sie es in einer Minute erneut"
fi

# --- 4) Von der Seite des Verwaltungs-Clusters (falls ein Tenant gesetzt ist) -----------------
# Nicht erforderlich für Lab 0: die Verbindung zum Cluster selbst oben hat bereits alles bewiesen.
# Aber wenn Tenant-Zugriff vorhanden ist — bestätigen wir die Bestellung und prüfen die Metrik-Erfassung.
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "Tenant-Zugriff ${COZY_KUBECONFIG} nicht gefunden — die Cluster-Bestellung auf der Verwaltungsseite wurde nicht geprüft" \
         "das ist kein Fehlschlag des Labs; der Pfad wird gesetzt mit: export COZY_KUBECONFIG=~/.kube/workshop"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "auf dem Verwaltungs-Cluster ist die Bestellung Kubernetes/lab im Zustand Ready"
    elif [ -n "$LAB_READY" ]; then
      warn "die Bestellung Kubernetes/lab ist noch nicht Ready (aktuell: ${LAB_READY})" \
           "der Cluster antwortet bereits, die Plattform gleicht ihn noch an den gewünschten Zustand an; schauen Sie nach: kubectl --kubeconfig ~/.kube/workshop -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "die Bestellung Kubernetes/lab wurde im Tenant ${TENANT_NS} nicht gefunden" \
           "falls Sie den Cluster anders benannt haben — setzen Sie Ihren eigenen Namen ein; oder Ihre Rolle im Tenant erlaubt diesen Befehl nicht (kein Lab-Fehler)"
    fi
    # Metrik-Erfassung: Lab 14 stützt sich auf Daten, die sich ab dem Moment der Aktivierung ansammeln.
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "Metrik-Erfassung ist aktiviert (wird in Lab 14 benötigt)"
    elif [ -n "$LAB_READY" ]; then
      warn "Metrik-Erfassung ist deaktiviert — Lab 14 bleibt ohne Daten" \
           "aktivieren: Dashboard → Anwendung lab → Addons → Monitoring agents (Metriken erscheinen nicht rückwirkend)"
    fi
  fi
else
  warn "COZY_TENANT ist nicht gesetzt — Prüfungen von der Seite des Verwaltungs-Clusters werden übersprungen" \
       "nicht erforderlich für Lab 0; zum Aktivieren: export COZY_TENANT=workshopXX"
fi

finish
