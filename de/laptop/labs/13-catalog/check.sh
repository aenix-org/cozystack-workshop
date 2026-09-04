#!/usr/bin/env bash
# Prüfung von Lab 13: Chart und Anwendungsdefinition sind bereit zur Übergabe an den Admin.
#
# Diese Prüfung ist BEWUSST lokal. Ein Tenant kann eine ApplicationDefinition nicht
# anwenden (das Objekt ist cluster-scoped), daher ist es sinnlos, im Cluster danach zu
# suchen: das Fehlen des Objekts ist nicht das Verschulden des Teilnehmers. Wir prüfen,
# wofür er verantwortlich ist: der Chart baut, das Schema funktioniert, die Definition
# wird geparst und stimmt mit dem Chart überein.
#
# Ausführen aus dem Lab-Ordner:
#   cd labs/13-catalog && ./check.sh
# Ein Cluster ist nicht erforderlich: ohne KUBECONFIG werden zwei Prüfungen mit einer Warnung
# übersprungen, nicht mit einem Fehler.

LAB_NAME="13-catalog"
LAB_TITLE="Lab 13 · Deine eigene Anwendung im Cozystack-Katalog"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- Werkzeuge -------------------------------------------------------------
# Ohne helm gibt es nichts zu prüfen, deshalb hält das Skript hier sofort an und schüttet
# nicht ein Dutzend gleicher Fehlermeldungen weiter unten aus.
if ! command -v helm >/dev/null 2>&1; then
  fail "helm ist auf dieser Maschine nicht installiert" \
       "installiere es: brew install helm (macOS) oder https://helm.sh/docs/intro/install/ — ohne helm kann das Lab nicht geprüft werden"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm ist vorhanden (${HELM_VER})"
evidence "helm-Version" "$HELM_VER"

# --- Chart ist vorhanden ---------------------------------------------------
# Wir unterscheiden „der Chart ist kaputt“ von „das Skript wurde aus dem falschen Ordner
# gestartet“. Der zweite Fehler kommt häufiger vor als der erste, und seine Meldung sollte
# eine eigene sein.
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "kein Chart in ${CHART} gefunden" \
       "starte das Skript aus dem Lab-Ordner: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- Linter ----------------------------------------------------------------
# helm lint liest den Chart als Text: es findet Tippfehler in Templates, fehlende Felder in
# Chart.yaml, Verweise auf nicht existierende Werte. Bis zum Cluster kommt es hier nicht.
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "der Chart besteht helm lint"
  evidence "helm lint" "$LINT_OUT"
else
  fail "der Chart besteht helm lint nicht" \
       "lies die Ausgabe unten und repariere die angezeigten Dateien: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- Rendern ---------------------------------------------------------------
# Leere Ausgabe und Ausgabe nur aus Kommentaren würde der Linter durchlassen, deshalb schauen
# wir, dass unter dem Gerenderten ein Deployment ist, und listen auf, was überhaupt herauskam.
# Wichtig ist hier nicht „der Befehl lief durch“, sondern „es sind echte Objekte entstanden“.
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "der Chart rendert, es entstehen Objekte: ${KINDS}"
  evidence "Was der Chart rendert" "$KINDS"
else
  fail "helm template hat kein einziges Deployment erzeugt" \
       "sieh dir den Render-Fehler an: helm template main chart"
  evidence "Ausgabe von helm template" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- der Chart wird von einem echten Cluster akzeptiert --------------------
# Die einzige Prüfung im gesamten Lab-Satz, die das Manifest gegen ein echtes Cluster-Schema
# abgleicht und nicht gegen Text.
#
# `helm lint` und `helm template` prüfen die Templates, aber NICHT das Kubernetes-Schema: ein
# Manifest mit einem Feld an der falschen Stelle lassen sie durch, während der Cluster es
# ablehnt. Am eigenen Leib erfahren — ein securityContext, versehentlich in volumes gesteckt,
# ging durch beide und fiel erst auf dem Server auseinander. Die Prüfung wird dort gebraucht,
# wo der Chart angewendet wird.
#
# Warum lint und template sie nicht ersetzen:
#   helm lint      schaut auf den Aufbau des Charts: Dateien sind vorhanden, Templates parsen;
#   helm template  setzt Werte ein und gibt Text aus — aber was das für Felder sind und ob
#                  ein solches Objekt sie überhaupt haben kann, weiß es nicht und kann es nicht wissen;
#   apply --dry-run=server schickt das Manifest an den apiserver, der es durch das Typ-Schema
#                  und die Admission-Kontrolle jagt und antwortet, ob er es annehmen würde, ohne
#                  dabei etwas zu erzeugen. Daher `unknown field` und eine Ablehnung per Policy —
#                  genau das, worüber der Chart beim Kunden stolpert.
# Das Flag --dry-run=client liefert diese Prüfung nicht: es parst das Manifest auf deiner Maschine.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # Eine Rechte-Ablehnung und eine Schema-Ablehnung sind verschiedene Dinge und dürfen nicht
  # verwechselt werden. Unter Tenant-Zugriff (~/.kube/workshop) gibt es überhaupt keine Rechte
  # auf Deployment und ConfigMap, deshalb kommt hier ein Forbidden — und das sagt nichts über
  # die Qualität des Charts aus. Eine inhaltliche Prüfung ist nur mit Zugriff auf den Cluster
  # `lab` möglich, wo du der vollwertige Besitzer bist.
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "serverseitige Chart-Prüfung übersprungen: der aktuelle Zugriff erlaubt sie nicht" \
         "führe sie mit Zugriff auf deinen eigenen Cluster aus: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "der Cluster lehnt den gerenderten Chart ab" \
         "sieh nach: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "Ablehnung des Servers" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "der Cluster akzeptiert den gerenderten Chart — die Felder und ihre Plätze sind korrekt"
  fi
else
  warn "Chart-Prüfung gegen den Cluster übersprungen: kein Zugriff" \
       "setze KUBECONFIG, um helm template durch kubectl apply --dry-run=server zu jagen"
fi

# --- Parameter erreichen die Manifeste tatsächlich -------------------------
# Ein Chart kann bauen und rendern, während ein Parameter nirgends eingesetzt wird —
# zum Beispiel wurde der Wert als Zahl fest ins Template geschrieben. Deshalb prüfen wir jeden
# Parameter in der Tat: wir setzen einen bewusst ungewöhnlichen Wert und suchen ihn im fertigen Manifest.
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "der Parameter replicas erreicht das Manifest (--set replicas=5 ergibt replicas: 5)"
else
  fail "der Parameter replicas erreicht das Manifest nicht" \
       "in templates/deployment.yaml sollte replicas: {{ .Values.replicas }} stehen"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "der Parameter external schaltet den Service-Typ auf LoadBalancer um"
else
  warn "der Parameter external schaltet den Service-Typ nicht um" \
       "kein Chart-Defekt, aber eine Konvention des Cozystack-Katalogs: das Feld external bei Anwendungen bedeutet genau externen Zugriff"
fi

# --- das Schema schützt tatsächlich ----------------------------------------
# Ein Schema, das nichts ablehnt, ist nutzlos. Wir prüfen, dass es ablehnt.
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "das Werte-Schema lehnt einen offensichtlich ungültigen Wert nicht ab (replicas=abc ging durch)" \
       "prüfe, dass values.schema.json neben values.yaml liegt und darin replicas als integer deklariert ist"
else
  ok "das Werte-Schema lehnt den falschen Typ ab (replicas=abc geht nicht durch)"
fi

# --- ApplicationDefinition: Pflichtfelder ----------------------------------
# Der Teilnehmer kann die Definition nicht anwenden, also sieht er auch die Ablehnung des
# apiserver nicht. Deshalb zählen wir die Pflichtfelder hier durch: ohne irgendeines davon
# bekommt der Admin bei sich eine Ablehnung, und aufklären muss es der Autor der Datei.
if [ ! -f "$APPDEF" ]; then
  fail "nicht gefunden: ${APPDEF}" \
       "die Datei sollte neben dem Chart liegen; nimm sie aus dem Lab-Repository"
else
  MISSING=""
  # Wir suchen die Schlüssel zeilenweise, ohne YAML zu parsen: PyYAML ist nicht auf jeder
  # Maschine, und eine Abhängigkeit nur zum Prüfen einer Datei mitzuschleppen lohnt nicht.
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
    ok "in der ApplicationDefinition sind alle Pflichtfelder vorhanden"
  else
    fail "in der ApplicationDefinition fehlen Felder:${MISSING}" \
         "gleiche mit der Erklärung im README ab — ohne irgendeines davon bekommt der Admin beim Anwenden eine Ablehnung"
  fi

  # --- das Schema in der Definition parst und stimmt mit dem Chart-Schema überein ---------
  # Das sind zwei getrennte Kopien ein und derselben Sache, und es gibt keinerlei Verbindung
  # zwischen ihnen. Driften sie auseinander, zeigt das Formular im Dashboard nicht die Felder,
  # die der Chart erwartet.
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "in der ApplicationDefinition ist openAPISchema leer" \
         "füge dort den Inhalt von chart/values.schema.json in einer Zeile ein"
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
        ok "das Schema in der Definition parst und stimmt mit dem Chart-Schema überein (${CMP#SAME })"
        evidence "Anwendungsparameter" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "das Schema in der Definition ist vom Chart-Schema abgedriftet: ${CMP#DIFF }" \
             "bring sie in Übereinstimmung: der Inhalt von openAPISchema ist chart/values.schema.json in einer Zeile"
        ;;
      BADJSON*)
        fail "openAPISchema parst nicht als JSON: ${CMP#BADJSON }" \
             "das Schema muss eine Zeile gültiges JSON unter 'openAPISchema: |-' sein"
        ;;
      *)
        warn "die Schemata konnten nicht abgeglichen werden (${CMP})" \
             "prüfe von Hand, dass openAPISchema mit chart/values.schema.json übereinstimmt"
        ;;
    esac
  fi

  # --- Icon -----------------------------------------------------------------
  # Das Dashboard erwartet ein SVG, in base64 gepackt, und holt das Bild nirgendwoher. Ein
  # Fehler hier ist still: das Manifest wird angewendet, aber im Katalog bleibt an der Stelle des
  # Icons leer. Deshalb dekodieren wir die Zeile und schauen, dass darin tatsächlich ein SVG steckt.
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "das Icon dekodiert aus base64 und erweist sich als SVG"
        evidence "Anfang des Icons" "$ICON_HEAD"
        ;;
      "")
        fail "das Icon dekodiert nicht aus base64" \
             "baue die Zeile neu auf: base64 -i icon.svg | tr -d '\\n' (unter Linux: base64 -w0 icon.svg)"
        ;;
      *)
        fail "das Icon dekodiert, aber es ist kein SVG" \
             "das Dashboard erwartet genau ein SVG; ein Rasterbild zeigt es als Müll an"
        ;;
    esac
  fi
fi

# --- Rechte: eine Ablehnung hier ist erwartet ------------------------------
# Das ist keine Prüfung des Teilnehmers, sondern eine Bestätigung des Aufbaus der Plattform.
# Deshalb ist die Antwort `no` ein Erfolg, und `yes` ein Grund zum Staunen, nicht zur Freude.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "bestätigt: eine ApplicationDefinition anzuwenden steht dir nicht zu (can-i -> no)"
      evidence "Rechte auf ApplicationDefinition" \
        "kubectl auth can-i create applicationdefinitions -> no
Das Objekt ist cluster-scoped und ändert den Katalog für alle Tenants, deshalb wendet es der Plattform-Admin an."
      ;;
    yes)
      warn "du hast die Rechte, eine ApplicationDefinition anzuwenden (can-i -> yes)" \
           "das heißt, du arbeitest unter einem Admin-Konto, nicht unter einem Tenant-Konto; das Lab ist für ein Tenant-Konto gedacht"
      ;;
    *)
      warn "der Cluster konnte nicht nach den Rechten gefragt werden" \
           "hindert die Abgabe des Labs nicht: die Prüfung ist lokal, ein Cluster wird hier nicht gebraucht"
      ;;
  esac
else
  warn "der Cluster wurde nicht abgefragt (KUBECONFIG nicht gesetzt oder antwortet nicht)" \
       "die Prüfung ist lokal, ein Cluster wird hier nicht gebraucht. Um die Rechte-Ablehnung zu sehen: export KUBECONFIG=~/.kube/workshop"
fi

finish
