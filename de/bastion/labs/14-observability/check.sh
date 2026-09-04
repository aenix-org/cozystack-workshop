#!/usr/bin/env bash
# Prüfung von Lab 14: Observability funktioniert wirklich.
#
# «Der Teilnehmer hat sich ein Diagramm angesehen» lässt sich nicht prüfen, und so zu tun, als ginge es, wäre unehrlich.
# Deshalb prüfen wir das, ohne das ein Diagramm unmöglich ist:
#   1) der Agent zur Metrikerfassung läuft im Cluster,
#   2) er sendet das Gesammelte an Ihren Tenant und nicht ins Leere,
#   3) auch die Logerfassung funktioniert — ohne sie ist das halbe Lab sinnlos,
#   4) im Cluster gibt es eine Spur der Last aus Lab 3, die sich in den Diagrammen finden lässt.

LAB_NAME="14-observability"
LAB_TITLE="Lab 14 · Observability: den eigenen Ausschlag in den Diagrammen finden"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- Erfassungs-Namespace ---------------------------------------------------
# Der Namespace allein beweist nichts: die Plattform legt dort auch den metrics-server ab,
# der auf jedem Cluster mit etcd installiert wird und nicht vom Addon abhängt. Wir prüfen sein
# Vorhandensein nur, um «Cluster nicht erreichbar» von «Erfassung ausgeschaltet» zu unterscheiden.
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "im Cluster gibt es keinen Namespace ${MON_NS} — der Cluster antwortet nicht wie erwartet" \
       "aktivieren Sie das Addon: Dashboard -> Kubernetes -> lab -> Bearbeiten -> Addons -> Monitoring agents. Beachten Sie: Aufzeichnungen erscheinen erst ab diesem Moment"
  finish
  exit $?
fi

# --- Metrik-Agent -----------------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "der Agent zur Metrikerfassung läuft (vmagent-Pods: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "der Agent zur Metrikerfassung existiert, läuft aber nicht (${VMAGENT_RUNNING} von ${VMAGENT_TOTAL} in Running)" \
       "sehen Sie sich die Ursache an: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "in ${MON_NS} gibt es keinen einzigen vmagent-Pod — das Addon Monitoring agents ist ausgeschaltet" \
       "aktivieren Sie es: Dashboard -> Kubernetes -> lab -> Bearbeiten -> Addons -> Monitoring agents. Aufzeichnungen beginnen sich erst ab diesem Moment anzusammeln, die Vergangenheit lässt sich nicht zurückholen"
fi
evidence "Erfassungs-Pods in ${MON_NS}" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- wohin genau die Metriken gehen -----------------------------------------
# Ein laufender Agent, der ins Leere schreibt, sieht genauso aus wie ein funktionierender.
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "Metriken werden an den Tenant gesendet${TARGET_NS:+ (${TARGET_NS})}"
      ;;
    *)
      warn "Metriken werden an eine Adresse gesendet, die nicht nach einer Tenant-Adresse aussieht" \
           "das kann in Ordnung sein, wenn der Leiter einen gemeinsamen Speicher eingerichtet hat; die Adresse steht in den Nachweisen"
      ;;
  esac
  evidence "Wohin die Metriken gesendet werden" "$RW_URL"
else
  warn "die Sendeadresse der Metriken konnte nicht gelesen werden" \
       "sehen Sie von Hand nach: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- Logerfassung -----------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "die Logerfassung läuft auf allen Knoten (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "die Logerfassung läuft nicht auf allen Knoten (${FB_READY:-0} von ${FB_DESIRED})" \
       "sehen Sie nach: kubectl -n ${MON_NS} get pods | grep fluent-bit — ohne sie funktioniert der Schritt mit der Suche in den Journalen nicht"
else
  warn "der Log-Collector fluent-bit wurde nicht gefunden" \
       "die Quelle vlogs-generic in Grafana bleibt leer; der Schritt mit der Suche in den Journalen lässt sich nicht durchführen"
fi

# --- gibt es überhaupt etwas in den Diagrammen zu suchen --------------------
# Metriken können perfekt erfasst werden, aber wenn es keine Last gab, gibt es nichts zu finden.
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "es gibt eine Spur der Last: die Autoskalierung wurde ausgelöst (zuletzt ${LAST_SCALE})"
    evidence "Zustand der Autoskalierung" "$(kubectl get hpa rickroll 2>/dev/null)
letzte Auslösung: ${LAST_SCALE}
aktuell Kopien: ${CUR:-?}, benötigt: ${DES:-?}"
  else
    warn "die Autoskalierung ist konfiguriert, wurde aber nie ausgelöst" \
         "die Stufe des Kopienwachstums werden Sie nicht finden; wiederholen Sie die Last aus Lab 3 mit dem fortio-Generator"
  fi
else
  warn "im Cluster gibt es keinen HorizontalPodAutoscaler namens rickroll" \
       "die Schritte mit Diagrammen in diesem Lab stützen sich auf Lab 3; ohne es finden Sie nur den CPU-Ausschlag, aber nicht die Stufe"
fi

# --- die Metriken der Anwendung selbst --------------------------------------
# Indirekt, aber wesentlich: wenn die Anwendungs-Pods leben, ist ihr Verbrauch in den Diagrammen zu sehen.
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "die Anwendungs-Pods sind vorhanden (${APP_PODS} Stück) — ihr Verbrauch ist in den Diagrammen sichtbar"
  evidence "Anwendungs-Pods" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "es gibt keine rickroll-Anwendungs-Pods im Cluster" \
       "die historischen Metriken aus der Zeit von Lab 3 sind dabei erhalten geblieben; stellen Sie in Grafana einfach jenen Zeitbereich ein"
fi

# --- wo man Grafana findet --------------------------------------------------
# Keine Prüfung, sondern eine Hilfe: die Grafana-Adresse suchen die Teilnehmer am längsten.
: "${COZY_KUBECONFIG:=$HOME/.kube/config}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "Grafana für Ihre Metriken: https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
die Metriken des Tenants ${TNS} werden im Namespace ${MON_TARGET} gespeichert"
    else
      warn "das Monitoring Ihres Tenants lebt in ${MON_TARGET}, aber die Grafana-Adresse konnte nicht gelesen werden" \
           "wenn ${MON_TARGET} nicht Ihr Namespace ist, dann ist Grafana gemeinsam: fragen Sie den Leiter nach der Adresse"
      evidence "Tenant-Monitoring" "Namespace mit Monitoring: ${MON_TARGET}"
    fi
  else
    warn "es konnte nicht bestimmt werden, wohin die Metriken des Tenants ${TNS} gehen" \
         "fragen Sie den Leiter nach der Grafana-Adresse oder finden Sie sie im Dashboard: Anwendung Monitoring -> Ingress"
  fi
else
  warn "die Grafana-Adresse ist nicht bestimmt" \
       "setzen Sie COZY_TENANT und COZY_KUBECONFIG, dann findet das Skript sie selbst; auf das Bestehen des Labs hat das keinen Einfluss"
fi

finish
