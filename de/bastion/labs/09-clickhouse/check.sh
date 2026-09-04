#!/usr/bin/env bash
# Prüfung von Lab 9: In ClickHouse liegt ein Journal der Durchgänge, und darüber wird ein Bericht berechnet.
#
# Wir prüfen nicht «der Dienst wurde erstellt», sondern das Wesentliche: die Tabelle existiert, hat
# nicht weniger als eine Million Zeilen, die Daten sind vielfältig und haben ausgeprägte Spitzen, der
# Monatsbericht läuft in Millisekunden, und eine Abfrage über eine einzelne Spalte liest nur einen
# kleinen Teil der Tabelle — das heißt, die Spaltenorientierung funktioniert wirklich und wird nicht
# nur behauptet.
#
# Ausführen (in jedem neuen Terminalfenster müssen die Variablen erneut gesetzt werden):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # deine Nummer statt XX
#   export CH_PASSWORD='Passwort des Benutzers analyst'
#   cd labs/09-clickhouse && ./check.sh
#
# Das Passwort wird nicht ausgegeben und landet nicht im Bericht.
# Das Skript startet Einweg-Pods mit curl, daher dauert es etwa eine Minute.

# Name und Titel werden von der gemeinsamen Bibliothek benötigt: sie signiert damit das Bericht-Artefakt.
# In lib.sh liegen ok/fail/warn/evidence/finish und die Umgebungsprüfungen unten — damit
# fünfzehn Prüfskripte einheitlich ausgeben und nicht jedes auf seine eigene Weise.
LAB_NAME="09-clickhouse"
LAB_TITLE="Lab 9 · Analytik über eine Million Zeilen"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Beide Prüfungen stoppen das Skript mit einer klaren Meldung, wenn die Cluster-Zugriffsdatei oder die
# Tenant-Nummer nicht gesetzt ist. Ohne sie würden weiter unten laufend kubectl-Fehler auflaufen.
need_kubeconfig
need_tenant

# Der Teilnehmer setzt COZY_TENANT als `workshop07`, während der Namespace
# `tenant-workshop07` heißt. Wir akzeptieren beide Schreibweisen.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Die Standardnamen sind dieselben wie im Lab. Die Schreibweise ${X:-Wert} bedeutet «nimm die
# Umgebungsvariable, und falls sie fehlt, setze den Wert ein»: die App anders benannt —
# führe sie als CH_APP=Name ./check.sh aus, das Skript muss nicht bearbeitet werden.
# Die Adresse ist intern, aus dem Cluster selbst: 8123 ist der Port der ClickHouse-HTTP-Schnittstelle.
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "ClickHouse-Adresse" "$CH_URL"

# --- 1. antwortet der Dienst überhaupt --------------------------------------
# /ping benötigt kein Passwort, daher ist dies die erste und günstigste Prüfung:
# sie trennt «keine Verbindung» von «Verbindung besteht, falsches Passwort».
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse antwortet unter der internen Adresse des Tenants"
else
  fail "ClickHouse antwortet nicht unter ${CH_HOST}" \
       "prüfe die Tenant-Nummer in COZY_TENANT und den App-Namen (Standard 'analytics'; sonst CH_APP=Name ./check.sh); im Dashboard muss die App im Bereitschaftszustand sein"
  finish
  exit $?
fi

# Alles Weitere erfordert die Anmeldung an der Datenbank. Ohne Passwort rät das Skript nicht und
# schweigt nicht, sondern sagt ehrlich, dass der Inhalt der Datenbank nicht geprüft wurde, und
# schließt den Bericht ab: sonst würde der Teilnehmer denken, die Prüfung sei bestanden.
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "die Variable CH_PASSWORD ist nicht gesetzt, der Inhalt der Datenbank wurde nicht geprüft" \
       "export CH_PASSWORD='Passwort des Benutzers ${CH_USER}' und starte das Skript erneut; das Passwort ist im Dashboard sichtbar, Secret clickhouse-${CH_APP}-credentials"
  finish
  exit $?
fi

# SQL von der Standardeingabe ausführen und die Antwort zurückgeben.
# Eine eigene Funktion, nicht in_cluster_curl: die Abfrage geht als POST-Body raus, und der Body
# braucht die Standardeingabe, die die gemeinsame Funktion nicht hat.
# Das Passwort gelangt als Umgebungsvariable aus einem temporären Secret in den Pod, nicht als Argument:
# alles, was in args landet, ist für jeden mit `get pods` sichtbar, liegt in etcd und taucht im Audit-
# Log auf. Genau darum geht es im Lab selbst — es mit einem Skript zu prüfen, das das Gegenteil tut,
# wäre mit zweierlei Maß gemessen.
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# Eine Zahl aus dem statistics-Block einer Antwort im JSON-Format herausziehen.
chstat() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
key = sys.argv[1]
src = d.get("statistics", {}) if key in ("elapsed",) else d
val = src.get(key, d.get("statistics", {}).get(key))
if val is None:
    sys.exit(1)
print(val)
' "$1" 2>/dev/null
}

# --- 2. die Tabelle existiert -----------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "Tabelle ${CH_TABLE} existiert"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse hat das Passwort des Benutzers ${CH_USER} nicht akzeptiert" \
         "prüfe das Passwort im Dashboard: App ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "Tabelle ${CH_TABLE} existiert nicht" \
         "erstelle sie: ch < 01-schema.sql (Schema-Erläuterung — in der README)"
  fi
  finish
  exit $?
fi

# --- 3. wie viele Daten und wie vielfältig sie sind -------------------------
# Eine Abfrage statt sechs: jeder ch_query-Aufruf startet einen Pod, und sechs Pods hintereinander
# würden die Prüfung ohne Grund in ein minutenlanges Warten verwandeln.
STATS="$(ch_query <<SQL
SELECT
    (SELECT count() FROM ${CH_TABLE}),
    (SELECT uniqExact(entrance) FROM ${CH_TABLE}),
    (SELECT uniqExact(pass_type) FROM ${CH_TABLE}),
    (SELECT uniqExact(toStartOfMonth(created_at)) FROM ${CH_TABLE}),
    (SELECT max(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT min(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT sum(data_uncompressed_bytes) FROM system.columns
      WHERE database = currentDatabase() AND table = '${CH_TABLE}')
SQL
)"

ROWS="$(printf '%s' "$STATS" | awk 'NR==1{print $1}')"
UNIQ_ENT="$(printf '%s' "$STATS" | awk 'NR==1{print $2}')"
UNIQ_TYPE="$(printf '%s' "$STATS" | awk 'NR==1{print $3}')"
UNIQ_MONTH="$(printf '%s' "$STATS" | awk 'NR==1{print $4}')"
PEAK_MAX="$(printf '%s' "$STATS" | awk 'NR==1{print $5}')"
PEAK_MIN="$(printf '%s' "$STATS" | awk 'NR==1{print $6}')"
TABLE_BYTES="$(printf '%s' "$STATS" | awk 'NR==1{print $7}')"

for v in ROWS UNIQ_ENT UNIQ_TYPE UNIQ_MONTH PEAK_MAX PEAK_MIN TABLE_BYTES; do
  eval "val=\$$v"
  case "$val" in
    ''|*[!0-9]*) eval "$v=0" ;;
  esac
done

if [ "$ROWS" -ge 1000000 ]; then
  ok "die Tabelle hat ${ROWS} Zeilen — eine Million wurde erzeugt"
else
  fail "die Tabelle hat ${ROWS} Zeilen, erwartet wurde eine Million" \
       "starte den Generator: ch < 02-generate.sql (Generator-Erläuterung — in der README)"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "die Daten sind vielfältig: Eingänge ${UNIQ_ENT}, Ausweistypen ${UNIQ_TYPE}, Monate ${UNIQ_MONTH}"
else
  fail "die Daten sind eintönig: Eingänge ${UNIQ_ENT}, Typen ${UNIQ_TYPE}, Monate ${UNIQ_MONTH}" \
       "auf solchen Daten zeigt der Bericht nichts; erzeuge neu: TRUNCATE TABLE ${CH_TABLE}, dann ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "die Daten haben ausgeprägte Spitzen nach Stunden (die geschäftigste Stunde zur ruhigsten — mindestens doppelt so viel)"
  evidence "Verteilung nach Stunden" "Maximum pro Stunde: ${PEAK_MAX}
Minimum pro Stunde: ${PEAK_MIN}"
else
  warn "keine Spitzen nach Stunden erkennbar: Maximum ${PEAK_MAX}, Minimum ${PEAK_MIN}" \
       "der Bericht «wann sind die Spitzen» ist auf solchen Daten sinnlos; prüfe, dass der Generator vollständig durchgelaufen ist"
fi

# --- 4. der Monatsbericht wird schnell berechnet ----------------------------
REPORT="$(ch_query <<SQL
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM ${CH_TABLE}
GROUP BY month
ORDER BY month
FORMAT JSON
SQL
)"

ELAPSED="$(printf '%s' "$REPORT" | chstat elapsed)"
READ_ROWS="$(printf '%s' "$REPORT" | chstat rows_read)"

if [ -z "$ELAPSED" ]; then
  fail "der Monatsbericht lief nicht" \
       "führe ihn manuell aus: ch < 03-report.sql und sieh dir den Fehlertext an"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # Wir halten die Schwelle nahe an dem, was das Lab verspricht. Die früheren fünf Sekunden zählten
  # einen Vier-Sekunden-Bericht als Erfolg — obwohl in der Lab-Kopfzeile «in Millisekunden berechnet»
  # steht. Das Skript darf nicht bestätigen, was es nicht geprüft hat.
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "der Monatsbericht wurde in ${MS} ms berechnet, gelesene Zeilen: ${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "der Monatsbericht dauerte ${MS} ms — das ist nicht die Größenordnung, um die es im Lab geht" \
         "eine Million Zeilen passen auf einem freien Stand in zehner Millisekunden; prüfe, dass der Dienst nicht mit einer benachbarten Last beschäftigt ist, und wiederhole"
  else
    warn "der Monatsbericht wurde in ${MS} ms berechnet — langsamer als erwartet, aber im vertretbaren Rahmen" \
         "auf einem ausgelasteten Stand kommt das vor; auf einem freien passt ein solcher Bericht in zehner Millisekunden"
  fi
  evidence "Monatsbericht" "Zeit: ${MS} ms
gelesene Zeilen: ${READ_ROWS}"
fi

# --- 5. Spaltenorientierung funktioniert, wird nicht nur behauptet ----------
# Die Abfrage berührt eine kleine Spalte. Ist der Speicher spaltenorientiert, wird deutlich
# weniger gelesen, als die ganze Tabelle wiegt.
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# Beide Größen sind UNKOMPRIMIERT: `bytes_read` in der Abfragestatistik ist das entpackte
# Volumen, und aus system.columns nehmen wir `data_uncompressed_bytes`. Der Vergleich mit
# `data_compressed_bytes` ergab einen Anteil der Größe auf der Platte und gab dem Teilnehmer
# eine falsche Zahl aus — bei einer gut komprimierten Tabelle konnte sie hundert Prozent übersteigen.
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "Lesen einer einzelnen Spalte" "gelesene Bytes: ${NARROW_BYTES}
ganze Tabelle ohne Kompression, Bytes: ${TABLE_BYTES}
Anteil: ${SHARE}%"
  # Eine Schwelle, nicht einfach «weniger als das Ganze». Eine schmale Spalte von sieben sollte
  # einstellige Prozent ergeben; «99% statt 100%» ist formal weniger, beweist aber nichts — und genau
  # das ist die Behauptung, die das Lab in seinen Titel stellt.
  if [ "$SHARE" -le 25 ]; then
    ok "die Abfrage über eine einzelne Spalte las ${SHARE}% der Tabellendaten — spaltenorientierter Speicher funktioniert"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "die Abfrage über eine einzelne Spalte las ${SHARE}% der Tabellendaten — weniger als das Ganze, aber der Gewinn ist bescheidener als erwartet" \
         "einstellige Prozent wurden erwartet; prüfe, dass die Abfrage eine schmale Spalte anspricht und nicht mehrere"
  else
    warn "die Abfrage über eine einzelne Spalte las nicht weniger als die ganze Tabelle" \
         "das kommt bei sehr kleinen Tabellen vor; prüfe, dass es wirklich eine Million Zeilen gibt"
  fi
else
  warn "es ließ sich nicht messen, wie viel die schmale Abfrage gelesen hat" \
       "führe manuell aus: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON und sieh dir bytes_read an"
fi

# finish gibt das Ergebnis aus und legt das Bericht-Artefakt in eine Datei ab; der Rückgabecode ist
# ungleich null, wenn mindestens eine Prüfung fehlgeschlagen ist.
finish
