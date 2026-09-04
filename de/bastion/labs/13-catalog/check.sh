#!/usr/bin/env bash
# Prüfung für Lab 13: Chart und Anwendungsdefinition sind bereit zur Übergabe an den Admin.
#
# Diese Prüfung ist ABSICHTLICH lokal. Ein Tenant kann eine ApplicationDefinition nicht
# anwenden (das Objekt ist cluster-scoped), daher ist die Suche danach im Cluster sinnlos:
# das Fehlen des Objekts ist nicht die Schuld des Teilnehmers. Wir prüfen, wofür er verantwortlich ist:
# das Chart baut, das Schema funktioniert, die Definition ist geparst und mit dem Chart konsistent.
#
# Ausführen aus dem Lab-Ordner:
#   cd labs/13-catalog && ./check.sh
# Ein Cluster ist nicht erforderlich: ohne KUBECONFIG werden zwei Prüfungen mit einer Warnung übersprungen,
# nicht mit einem Fehler.

LAB_NAME="13-catalog"
LAB_TITLE="Lab 13 · Ihre eigene Anwendung im Cozystack-Katalog"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- Werkzeuge -------------------------------------------------------------
# Ohne helm gibt es nichts zu prüfen, daher hält das Skript genau hier an, statt ein Dutzend
# identischer Fehlermeldungen weiter unten im Text auszuspucken.
if ! command -v helm >/dev/null 2>&1; then
  fail "helm ist auf dieser Maschine nicht installiert" \
       "installieren Sie es: brew install helm (macOS) oder https://helm.sh/docs/intro/install/ — ohne es kann das Lab nicht geprüft werden"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm ist vorhanden (${HELM_VER})"
evidence "helm-Version" "$HELM_VER"

# --- Chart vorhanden -------------------------------------------------------
# Wir unterscheiden „das Chart ist kaputt“ von „das Skript wurde aus dem falschen Ordner ausgeführt“. Der zweite
# Fehler ist häufiger als der erste, und seine Meldung sollte separat sein.
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "Chart nicht gefunden in ${CHART}" \
       "führen Sie das Skript aus dem Lab-Ordner aus: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- Linter ----------------------------------------------------------------
# helm lint liest das Chart als Text: es findet Tippfehler in Templates, fehlende Chart.yaml-
# Felder, Verweise auf nicht existierende Werte. Der Cluster wird hier nie erreicht.
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "Chart besteht helm lint"
  evidence "helm lint" "$LINT_OUT"
else
  fail "Chart besteht helm lint nicht" \
       "lesen Sie die Ausgabe unten und reparieren Sie die angegebenen Dateien: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- Render ----------------------------------------------------------------
# Leere Ausgabe und Ausgabe, die nur aus Kommentaren besteht, würden am Linter vorbeikommen, daher prüfen wir,
# dass unter der gerenderten Ausgabe ein Deployment ist, und listen auf, was tatsächlich erzeugt wurde.
# Der Punkt hier ist nicht „der Befehl lief“, sondern „echte Objekte kamen heraus“.
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "Chart rendert und erzeugt Objekte: ${KINDS}"
  evidence "Was das Chart rendert" "$KINDS"
else
  fail "helm template hat kein einziges Deployment erzeugt" \
       "sehen Sie sich den Render-Fehler an: helm template main chart"
  evidence "helm-template-Ausgabe" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- Chart wird von einem echten Cluster akzeptiert ------------------------
# Die einzige Prüfung im gesamten Lab-Satz, die das Manifest gegen ein echtes Cluster-Schema verifiziert
# statt gegen Text.
#
# `helm lint` und `helm template` prüfen Templates, aber NICHT das Kubernetes-Schema: ein Manifest
# mit einem Feld an der falschen Stelle rutscht an ihnen vorbei, aber der Cluster lehnt es ab. Auf die harte
# Tour gelernt — ein securityContext, der versehentlich in volumes eingefügt wurde, bestand beide und fiel erst
# auf dem Server auseinander. Die Prüfung wird dort gebraucht, wo das Chart tatsächlich angewendet wird.
#
# Warum lint und template sie nicht ersetzen:
#   helm lint      betrachtet die Struktur des Charts: Dateien vorhanden, Templates parsen;
#   helm template  setzt Werte ein und erzeugt Text — aber was diese Felder sind und ob
#                  ein solches Objekt sie überhaupt hat, weiß es nicht und kann es nicht wissen;
#   apply --dry-run=server sendet das Manifest an den apiserver, der es durch das Typ-Schema
#                  und durch Admission Control laufen lässt und antwortet, ob er es akzeptieren würde,
#                  dabei nichts erzeugend. Daher kommen `unknown field` und eine Policy-Ablehnung —
#                  genau das, worüber das Chart beim Kunden stolpert.
# Das Flag --dry-run=client liefert diese Prüfung nicht: es parst das Manifest auf Ihrer Maschine.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # Eine Rechte-Ablehnung und eine Schema-Ablehnung sind verschiedene Dinge und dürfen nicht verwechselt werden. Unter
  # Tenant-Zugriff (~/.kube/config) gibt es überhaupt keine Rechte auf Deployment und ConfigMap, daher kommt hier
  # Forbidden an — und das sagt nichts über die Qualität des Charts aus. Eine inhaltliche Prüfung
  # ist nur mit Zugriff auf den `lab`-Cluster möglich, wo Sie der volle Eigentümer sind.
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "serverseitige Chart-Prüfung übersprungen: der aktuelle Zugriff erlaubt ihre Ausführung nicht" \
         "führen Sie sie mit Zugriff auf Ihren eigenen Cluster aus: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "Cluster lehnt das gerenderte Chart ab" \
         "sehen Sie sich an: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "Server-Ablehnung" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "Cluster akzeptiert das gerenderte Chart — die Felder und ihre Stellen sind korrekt"
  fi
else
  warn "Chart-Prüfung am Cluster übersprungen: kein Zugriff" \
       "setzen Sie KUBECONFIG, um helm template durch kubectl apply --dry-run=server zu leiten"
fi

# --- Parameter erreichen die Manifeste tatsächlich -------------------------
# Ein Chart kann bauen und rendern, und dennoch wird ein Parameter nirgends eingesetzt —
# zum Beispiel wurde der Wert als literale Zahl in das Template geschrieben. Also prüfen wir jeden
# Parameter praktisch: wir setzen einen bewusst ungewöhnlichen Wert und suchen ihn im fertigen Manifest.
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "der replicas-Parameter erreicht das Manifest (--set replicas=5 ergibt replicas: 5)"
else
  fail "der replicas-Parameter erreicht das Manifest nicht" \
       "templates/deployment.yaml sollte replicas: {{ .Values.replicas }} enthalten"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "der external-Parameter schaltet den Service-Typ auf LoadBalancer um"
else
  warn "der external-Parameter schaltet den Service-Typ nicht um" \
       "kein Chart-Fehler, aber eine Cozystack-Katalog-Konvention: das external-Feld bei Anwendungen bedeutet genau externen Zugriff"
fi

# --- das Schema schützt tatsächlich ----------------------------------------
# Ein Schema, das nichts ablehnt, ist nutzlos. Wir prüfen, dass es ablehnt.
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "das Werte-Schema lehnt einen bewusst ungültigen Wert nicht ab (replicas=abc ging durch)" \
       "prüfen Sie, dass values.schema.json neben values.yaml liegt und darin replicas als integer deklariert ist"
else
  ok "das Werte-Schema lehnt den falschen Typ ab (replicas=abc geht nicht durch)"
fi

# --- ApplicationDefinition: Pflichtfelder ----------------------------------
# Der Teilnehmer kann die Definition nicht anwenden, also wird er die Ablehnung des apiservers nicht sehen.
# Deshalb zählen wir die Pflichtfelder hier: ohne eines von ihnen bekommt der Admin auf seiner
# Seite eine Ablehnung, und der Autor der Datei ist derjenige, der es klären muss.
if [ ! -f "$APPDEF" ]; then
  fail "${APPDEF} nicht gefunden" \
       "die Datei sollte neben dem Chart liegen; nehmen Sie sie aus dem Lab-Repository"
else
  MISSING=""
  # Wir suchen Schlüssel Zeile für Zeile, ohne YAML zu parsen: PyYAML ist nicht auf jeder Maschine,
  # und eine Abhängigkeit hereinzuziehen, nur um eine Datei zu prüfen, lohnt sich nicht.
  check_key() {
    grep -Eq "$1" "$APPDEF" || MISSING="$MISSING $2"
  }
  check_key '^kind:[[:space:]]+ApplicationDefinition[[:space:]]*$' 'kind: ApplicationDefinition'
  check_key '^apiVersion:[[:space:]]+cozystack\.io/v1alpha1[[:space:]]*$' 'apiVersion: cozystack.io/v1alpha1'
  check_key '^[[:space:]]{4}kind:[[:space:]]+\S+' 'application.kind'
  check_key '^[[:space:]]{4}plural:[[:space:]]+\S+' 'application.plural'
  check_key '^[[:space:]]{4}singular:[[:space:]]+\S+' 'application.singular'
  check_key '^[[:space:]]{4}openAPISchema:' 'application.openAPISchema'
  check_key '^[[:space:]]{4}prefix:[[:space:]]+\S+' 'release.prefix'
  check_key '^[[:space:]]{6}kind:[[:space:]]+(OCIRepository|HelmChart|ExternalArtifact)' 'release.chartRef.kind'
  check_key '^[[:space:]]{4}category:[[:space:]]+\S+' 'dashboard.category'
  check_key '^[[:space:]]{4}icon:[[:space:]]+\S+' 'dashboard.icon'

  if [ -z "$MISSING" ]; then
    ok "alle Pflichtfelder sind in der ApplicationDefinition vorhanden"
  else
    fail "in der ApplicationDefinition fehlen Felder:${MISSING}" \
         "gleichen Sie mit dem Durchgang im README ab — ohne eines von ihnen bekommt der Admin beim Anwenden eine Ablehnung"
  fi

  # --- das Schema in der Definition parst und passt zum Schema des Charts ---
  # Das sind zwei getrennte Kopien derselben Sache, ohne jegliche Verbindung dazwischen.
  # Wenn sie auseinandergehen, zeigt das Formular im Dashboard andere Felder als das Chart erwartet.
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "openAPISchema ist leer in der ApplicationDefinition" \
         "fügen Sie den Inhalt von chart/values.schema.json dort als einzelne Zeile ein"
  else
    CMP="$(SCHEMA_LINE="$SCHEMA_LINE" python3 - "$CHART/values.schema.json" <<'PY' 2>&1
import os, sys, json
try:
    inline = json.loads(os.environ["SCHEMA_LINE"])
except Exception as e:
    print("BADJSON %s" % e); raise SystemExit
try:
    chart = json.load(open(sys.argv[1]))
except Exception as e:
    print("NOCHART %s" % e); raise SystemExit
a = sorted((inline.get("properties") or {}).keys())
b = sorted((chart.get("properties") or {}).keys())
if a == b:
    print("SAME %s" % ",".join(a))
else:
    only_def = sorted(set(a) - set(b))
    only_chart = sorted(set(b) - set(a))
    print("DIFF nur in der Definition: %s | nur im Chart: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "das Schema in der Definition parst und passt zum Schema des Charts (${CMP#SAME })"
        evidence "Anwendungsparameter" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "das Schema in der Definition ist vom Schema des Charts abgewichen: ${CMP#DIFF }" \
             "bringen Sie sie in Übereinstimmung: der Inhalt von openAPISchema ist chart/values.schema.json als einzelne Zeile"
        ;;
      BADJSON*)
        fail "openAPISchema parst nicht als JSON: ${CMP#BADJSON }" \
             "das Schema muss eine einzelne Zeile gültiges JSON unter 'openAPISchema: |-' sein"
        ;;
      *)
        warn "konnte die Schemata nicht vergleichen (${CMP})" \
             "prüfen Sie von Hand, dass openAPISchema mit chart/values.schema.json übereinstimmt"
        ;;
    esac
  fi

  # --- Icon -----------------------------------------------------------------
  # Das Dashboard erwartet ein in base64 gepacktes SVG und geht nirgendwohin für das Bild. Der Fehler
  # hier ist still: das Manifest wird angewendet, aber im Katalog bleibt der Platz des Icons leer. Also
  # dekodieren wir die Zeichenkette und prüfen, dass darin wirklich ein SVG ist.
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "das Icon dekodiert aus base64 und stellt sich als SVG heraus"
        evidence "Anfang des Icons" "$ICON_HEAD"
        ;;
      "")
        fail "das Icon dekodiert nicht aus base64" \
             "bauen Sie die Zeichenkette neu: base64 -i icon.svg | tr -d '\\n' (unter Linux: base64 -w0 icon.svg)"
        ;;
      *)
        fail "das Icon dekodiert, aber es ist kein SVG" \
             "das Dashboard erwartet genau ein SVG; ein Rasterbild zeigt es als Müll an"
        ;;
    esac
  fi
fi

# --- Rechte: eine Ablehnung hier ist erwartet ------------------------------
# Dies ist keine Prüfung des Teilnehmers, sondern eine Bestätigung, wie die Plattform gebaut ist. Also
# ist die Antwort `no` ein Erfolg, und `yes` ein Grund, überrascht zu sein, nicht erfreut.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "bestätigt: Sie dürfen keine ApplicationDefinition anwenden (can-i -> no)"
      evidence "Rechte auf ApplicationDefinition" \
        "kubectl auth can-i create applicationdefinitions -> no
Das Objekt ist cluster-scoped und ändert den Katalog für alle Tenants, daher ist es der Plattform-Admin, der es anwendet."
      ;;
    yes)
      warn "Sie haben Rechte, eine ApplicationDefinition anzuwenden (can-i -> yes)" \
           "das bedeutet, Sie arbeiten unter einem Admin-Konto, nicht einem Tenant-Konto; das Lab ist für ein Tenant-Konto ausgelegt"
      ;;
    *)
      warn "konnte den Cluster nicht nach Rechten fragen" \
           "beeinträchtigt das Bestehen des Labs nicht: die Prüfung ist lokal, der Cluster wird hier nicht gebraucht"
      ;;
  esac
else
  warn "Cluster wurde nicht abgefragt (KUBECONFIG ist nicht gesetzt oder antwortet nicht)" \
       "die Prüfung ist lokal, der Cluster wird hier nicht gebraucht. Um die Rechte-Ablehnung zu sehen: export KUBECONFIG=~/.kube/config"
fi

finish
