#!/usr/bin/env bash
# Prüfung für Lab 0: Der Trainings-Cluster läuft und Sie haben sich mit ihm verbunden.
#
# Wir prüfen nicht «das Objekt wurde erstellt», sondern dass der Cluster im Kern funktioniert:
#   1) der lab-Cluster antwortet über Ihre Zugriffsdatei (KUBECONFIG=~/lab.kubeconfig),
#   2) mindestens ein Knoten ist im Zustand Ready,
#   3) auf den Knoten sind freie Ressourcen für künftige Anwendungen vorhanden.
# Wenn COZY_TENANT gesetzt ist — prüfen wir zusätzlich auf dem MANAGEMENT-Cluster, dass die
# Bestellung Kubernetes/lab den Zustand Ready erreicht hat und die Metrikerfassung aktiviert ist (ohne sie ist Lab 14 leer).
#
# Wird auf der VM ausgeführt, aus dem Ordner dieses Labs:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # für Prüfungen auf der Tenant-Seite (optional)
#     cd labs/00-cluster && ./check.sh
#
# Das Skript liest nur — es ändert den Zustand des Clusters nicht.
LAB_NAME="00-cluster"
LAB_TITLE="Lab 0 · Ihr eigener Kubernetes-Cluster"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne Zugriff auf den lab-Cluster selbst gibt es nichts zu prüfen — das ist der wichtigste
# Nachweis des Labs. need_kubeconfig hält das Skript mit einem verständlichen Hinweis an,
# wenn KUBECONFIG nicht gesetzt ist oder der Cluster nicht antwortet.
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) Verbindung zum lab-Cluster -------------------------------------------
# need_kubeconfig hat bereits sichergestellt, dass der Server antwortet. Wir halten das als eigenes
# Ergebnis fest und legen die Server-Version in den Bericht.
KVER="$(server_version)"
ok "lab-Cluster antwortet — die Zugriffsdatei funktioniert"
[ -n "$KVER" ] && evidence "Server-Version des lab-Clusters" "$KVER"

# --- 2) Knoten im Einsatz ----------------------------------------------------
# Wir zählen, wie viele Knoten im Zustand Ready sind. Eine leere Liste bedeutet, dass der Cluster
# läuft, aber die Knotengruppe md0 sich noch aufbaut.
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "Knoten im Einsatz: ${READY_NODES} von ${TOTAL_NODES} im Zustand Ready"
  [ -n "$NODES_WIDE" ] && evidence "Cluster-Knoten" "$NODES_WIDE"
else
  fail "kein Knoten ist im Zustand Ready (Knoten insgesamt: ${TOTAL_NODES:-0})" \
       "warten Sie ein paar Minuten, bis sich die Knotengruppe md0 aufbaut; der Status steht im Dashboard der lab-Anwendung, oder: kubectl get nodes"
  evidence "Cluster-Knoten" "${NODES_WIDE:-keine Knoten}"
fi

# --- 3) Gibt es Platz für künftige Anwendungen ------------------------------
# allocatable des ersten Knotens: wenn keine Ressourcen da sind, startet weiter nichts.
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "auf den Knoten sind Ressourcen für Anwendungen vorhanden (auf dem Knoten: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "Freie Knotenressourcen (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "freie Knotenressourcen konnten nicht gelesen werden" \
       "in der Regel ist das vorübergehend — wiederholen Sie es in einer Minute"
fi

# --- 4) Von der Seite des Management-Clusters (wenn ein Tenant gesetzt ist) ---
# Nicht erforderlich für Lab 0: die Verbindung zum Cluster selbst oben hat bereits alles bewiesen.
# Aber wenn Tenant-Zugriff vorhanden ist — bestätigen wir die Bestellung und prüfen die Metrikerfassung.
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "Tenant-Zugriff ${COZY_KUBECONFIG} nicht gefunden — die Cluster-Bestellung auf dem Management-Cluster wurde nicht geprüft" \
         "das ist kein Fehlschlag des Labs; der Pfad wird gesetzt mit: export COZY_KUBECONFIG=~/.kube/config"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "auf dem Management-Cluster ist die Bestellung Kubernetes/lab im Zustand Ready"
    elif [ -n "$LAB_READY" ]; then
      warn "die Bestellung Kubernetes/lab ist noch nicht Ready (aktuell: ${LAB_READY})" \
           "der Cluster antwortet bereits, die Plattform gleicht ihn noch an den gewünschten Zustand an; sehen Sie nach mit: kubectl --kubeconfig ~/.kube/config -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "die Bestellung Kubernetes/lab im Tenant ${TENANT_NS} nicht gefunden" \
           "wenn Sie den Cluster anders benannt haben — setzen Sie Ihren eigenen Namen ein; oder die Rolle im Tenant erlaubt diesen Befehl nicht (kein Lab-Fehler)"
    fi
    # Metrikerfassung: Lab 14 stützt sich auf Daten, die ab dem Moment der Aktivierung anfallen.
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "Metrikerfassung ist aktiviert (wird in Lab 14 benötigt)"
    elif [ -n "$LAB_READY" ]; then
      warn "Metrikerfassung ist deaktiviert — Lab 14 bleibt ohne Daten" \
           "aktivieren: Dashboard → lab-Anwendung → Addons → Monitoring agents (Metriken erscheinen nicht rückwirkend)"
    fi
  fi
else
  warn "COZY_TENANT ist nicht gesetzt — Prüfungen auf der Seite des Management-Clusters werden übersprungen" \
       "nicht erforderlich für Lab 0; zum Aktivieren: export COZY_TENANT=workshopXX"
fi

finish
