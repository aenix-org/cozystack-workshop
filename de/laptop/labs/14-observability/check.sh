#!/usr/bin/env bash
# Prüfung für Lab 14: Observability funktioniert wirklich.
#
# „Der Teilnehmer hat sich ein Diagramm angesehen" lässt sich nicht überprüfen, und so zu tun, als ob, wäre unehrlich.
# Deshalb prüfen wir die Dinge, ohne die ein Diagramm unmöglich ist:
#   1) der Agent zur Metrik-Erfassung läuft im Cluster,
#   2) er sendet das Erfasste an deinen Tenant und nicht ins Leere,
#   3) auch die Log-Erfassung funktioniert — ohne sie ist die halbe Lab sinnlos,
#   4) im Cluster gibt es eine Spur der Last aus Lab 3, die sich in den Diagrammen finden lässt.

LAB_NAME="14-observability"
LAB_TITLE="Lab 14 · Observability: finde deinen Ausschlag in den Diagrammen"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- Erfassungs-Namespace ---------------------------------------------------
# Der Namespace allein beweist nichts: die Plattform legt dort auch den metrics-server ab,
# der auf jedem Cluster mit etcd installiert wird und nicht vom Addon abhängt. Wir prüfen
# seine Existenz nur, um „Cluster nicht erreichbar" von „Erfassung deaktiviert" zu unterscheiden.
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "im Cluster gibt es keinen Namespace ${MON_NS} — der Cluster antwortet anders als erwartet" \
       "aktiviere das Addon: Dashboard -> Kubernetes -> lab -> bearbeiten -> Addons -> Monitoring agents. Beachte: Aufzeichnungen entstehen erst ab diesem Zeitpunkt"
  finish
  exit $?
fi

# --- Metrik-Agent -----------------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "der Agent zur Metrik-Erfassung läuft (vmagent-Pods: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "der Agent zur Metrik-Erfassung existiert, läuft aber nicht (${VMAGENT_RUNNING} von ${VMAGENT_TOTAL} in Running)" \
       "sieh dir die Ursache an: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "in ${MON_NS} gibt es keinen einzigen vmagent-Pod — das Addon Monitoring agents ist deaktiviert" \
       "aktiviere es: Dashboard -> Kubernetes -> lab -> bearbeiten -> Addons -> Monitoring agents. Aufzeichnungen beginnen sich erst ab diesem Zeitpunkt anzusammeln; Vergangenes lässt sich nicht wiederherstellen"
fi
evidence "Erfassungs-Pods in ${MON_NS}" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- wohin die Metriken genau gehen -----------------------------------------
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
      warn "Metriken werden an eine Adresse gesendet, die nicht tenant-spezifisch aussieht" \
           "das kann in Ordnung sein, wenn der Leiter einen gemeinsamen Speicher eingerichtet hat; die Adresse steht in den Nachweisen"
      ;;
  esac
  evidence "Wohin die Metriken gesendet werden" "$RW_URL"
else
  warn "die Sendeadresse der Metriken konnte nicht gelesen werden" \
       "sieh von Hand nach: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- Log-Erfassung ----------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "die Log-Erfassung läuft auf allen Knoten (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "die Log-Erfassung läuft nicht auf allen Knoten (${FB_READY:-0} von ${FB_DESIRED})" \
       "sieh nach: kubectl -n ${MON_NS} get pods | grep fluent-bit — ohne sie funktioniert der Schritt mit der Log-Suche nicht"
else
  warn "der Log-Sammler fluent-bit wurde nicht gefunden" \
       "die Quelle vlogs-generic in Grafana wird leer sein; der Schritt mit der Log-Suche lässt sich nicht durchführen"
fi

# --- gibt es etwas in den Diagrammen zu suchen ------------------------------
# Metriken können perfekt erfasst werden, aber wenn es keine Last gab, gibt es nichts zu finden.
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "eine Lastspur existiert: das Autoscaling hat ausgelöst (zuletzt ${LAST_SCALE})"
    evidence "Autoscaling-Zustand" "$(kubectl get hpa rickroll 2>/dev/null)
letzte Auslösung: ${LAST_SCALE}
aktuelle Replicas: ${CUR:-?}, gewünscht: ${DES:-?}"
  else
    warn "das Autoscaling ist konfiguriert, hat aber nie ausgelöst" \
         "die Stufe des Replica-Wachstums wirst du nicht finden; wiederhole die Last aus Lab 3 mit dem fortio-Generator"
  fi
else
  warn "im Cluster gibt es keinen HorizontalPodAutoscaler mit dem Namen rickroll" \
       "die Diagramm-Schritte in dieser Lab stützen sich auf Lab 3; ohne sie findest du nur den CPU-Ausschlag, aber nicht die Stufe"
fi

# --- die Anwendungsmetriken selbst ------------------------------------------
# Indirekt, aber im Kern: wenn die Anwendungs-Pods leben, ist ihr Verbrauch in den Diagrammen zu sehen.
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "die Anwendungs-Pods sind vorhanden (${APP_PODS} Stück) — ihr Verbrauch ist in den Diagrammen sichtbar"
  evidence "Anwendungs-Pods" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "es gibt keine rickroll-Anwendungs-Pods im Cluster" \
       "die historischen Metriken aus der Zeit von Lab 3 sind dabei erhalten geblieben; stelle in Grafana einfach diesen Zeitbereich ein"
fi

# --- wo man Grafana findet --------------------------------------------------
# Keine Prüfung, sondern Hilfe: nach der Grafana-Adresse suchen die Teilnehmer am längsten.
: "${COZY_KUBECONFIG:=$HOME/.kube/workshop}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "Grafana für deine Metriken: https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
die Metriken des Tenants ${TNS} werden im Namespace ${MON_TARGET} gespeichert"
    else
      warn "das Monitoring deines Tenants lebt in ${MON_TARGET}, aber die Grafana-Adresse konnte nicht gelesen werden" \
           "wenn ${MON_TARGET} nicht dein Namespace ist, dann ist Grafana gemeinsam: frag den Leiter nach der Adresse"
      evidence "Tenant-Monitoring" "Namespace mit Monitoring: ${MON_TARGET}"
    fi
  else
    warn "es konnte nicht bestimmt werden, wohin die Metriken des Tenants ${TNS} gehen" \
         "frag den Leiter nach der Grafana-Adresse oder finde sie im Dashboard: Anwendung Monitoring -> Ingress"
  fi
else
  warn "die Grafana-Adresse ist nicht bestimmt" \
       "setze COZY_TENANT und COZY_KUBECONFIG, und das Skript findet sie selbst; auf das Bestehen der Lab hat das keinen Einfluss"
fi

finish
