#!/usr/bin/env bash
# Prüfung von Lab 10: In MongoDB liegen Ausweise verschiedener Form und man sucht nach ihnen.
#
# Wir prüfen nicht «der Dienst wurde erstellt», sondern das Wesentliche: Die Sammlung enthält Dokumente aller vier
# Formen, die Suche nach einem verschachtelten Feld und innerhalb einer Liste funktioniert, auf ein seltenes Feld
# ist ein dünn besetzter Index gebaut, der Schema-Validator ist eingeschaltet, und Dokumente ohne Typ
# sind keine mehr übrig.
#
# Aufruf (in jedem neuen Terminalfenster werden die Variablen erneut gesetzt):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # eigene Nummer statt XX
#   export MONGO_PASSWORD='Passwort des Benutzers passapp'
#   cd labs/10-mongodb && ./check.sh
#
# Das Passwort wird nicht ausgegeben und landet nicht im Bericht.
# Das Skript startet Wegwerf-Pods und läuft daher etwa eine Minute.

# Name und Titel werden von der gemeinsamen Bibliothek benötigt: Sie signiert damit das Bericht-Artefakt.
# In lib.sh liegen ok/fail/warn/evidence/finish und die Umgebungsprüfungen unten — damit
# fünfzehn Prüfskripte gleich ausgeben und nicht jedes auf seine eigene Weise.
LAB_NAME="10-mongodb"
LAB_TITLE="Lab 10 · Dokumentenspeicher"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Beide Prüfungen stoppen das Skript mit einer klaren Meldung, wenn die Cluster-Zugriffsdatei
# oder die Tenant-Nummer nicht gesetzt ist. Ohne sie würden sich weiter unten kubectl-Fehler häufen.
need_kubeconfig
need_tenant

# Der Teilnehmer setzt COZY_TENANT als `workshop07`, während der Namespace
# `tenant-workshop07` heißt. Wir akzeptieren beide Schreibweisen.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Die Standardnamen sind dieselben wie im Lab. Die Schreibweise ${X:-Wert} bedeutet «nimm
# die Umgebungsvariable, und falls sie fehlt, setze den Wert ein»: hast du die Anwendung
# anders benannt — starte als MONGO_APP=name ./check.sh, das Skript muss nicht geändert werden.
# Die Adresse ist intern, aus dem Cluster selbst; rs0 im Namen ist das Replikat-Set, in dem
# unsere einzige Kopie lebt.
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "MongoDB-Adresse" "$MONGO_HOST"

# --- 1. gibt es überhaupt Verbindung zum Port -------------------------------
# MongoDB antwortet auf ihrem Port auf eine HTTP-Anfrage mit einem klaren Satz darüber, dass
# man hierher mit einem Treiber kommt, nicht mit einem Browser. Das genügt, um
# «Name wird nicht aufgelöst / Port geschlossen» von «Verbindung besteht, falsche Zugangsdaten» zu unterscheiden.
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB antwortet unter der internen Adresse des Tenants"
else
  fail "keine Verbindung zu MongoDB unter der Adresse ${MONGO_HOST}" \
       "prüfe die Tenant-Nummer in COZY_TENANT und den Anwendungsnamen (Standard 'passes'; sonst MONGO_APP=name ./check.sh); im Dashboard muss die Anwendung in einem bereiten Zustand sein"
  finish
  exit $?
fi

# Alles Weitere erfordert die Anmeldung an der Datenbank. Ohne Passwort rät das Skript nicht und schweigt nicht,
# sondern sagt ehrlich, dass der Datenbankinhalt nicht geprüft wurde, und schließt den Bericht ab: sonst
# würde der Teilnehmer meinen, die Prüfung sei bestanden.
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "die Variable MONGO_PASSWORD ist nicht gesetzt, der Datenbankinhalt wurde nicht geprüft" \
       "export MONGO_PASSWORD='Passwort des Benutzers ${MONGO_USER}' und starte das Skript erneut"
  finish
  exit $?
fi

# Das Passwort wird prozent-kodiert: die Zeichen @ : / ? # % darin würden sonst die Verbindungs-
# zeichenkette zerstören, und der Mensch bekäme einen unklaren Parse-Fehler statt «falsches Passwort».
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ Die Verbindungszeichenkette enthält das Passwort und wird als Pod-Argument übergeben. Das ist ein bewusster
# Kompromiss: siehe `in_cluster_with_secrets` in check/lib.sh — ein sicherer Weg existiert, aber
# er ist ohne Überkomplizierung nicht mit einem mehrzeiligen --eval vereinbar. Der Pod lebt Sekunden und
# räumt hinter sich auf; das Passwort landet nicht im Bericht. In Produktivskripten mach das nicht.
#
# Alle Prüfungen in einem Durchgang: Jeder Aufruf startet einen Pod, und zehn Pods hintereinander
# würden die Prüfung ohne Grund in eine mehrminütige Warterei verwandeln.
# Nach außen wird eine einzige JSON-Zeile ausgegeben, danach zerlegt python sie.
# `--overrides` mit securityContext: Ohne ihn würde der Pod in einem Cluster mit dem Profil
# `restricted` nicht erstellt, und das Lab würde aus einem Grund scheitern, der den Teilnehmer nichts angeht.
# `--command --` bleibt: kubectl fügt es mit dem Override zusammen, in dem nur die
# Sicherheitsfelder gesetzt sind.
# Das Programm für mongosh. Doppelte Anführungszeichen darin sind sicher: Der Text geht nach außen
# durch python, das ihn selbst in Anführungszeichen setzt, und die Datenbank- und Sammlungsnamen werden
# über die Marker unten eingesetzt.
MONGO_EVAL=$(cat <<'JSEOF'

var out = {};
try {
  var c = db.getSiblingDB("__DB__").getCollection("__COLL__");
  out.ok = 1;
  out.total = c.countDocuments({});
  out.types = c.distinct("type").length;
  out.withCar = c.countDocuments({ "car.plate": { $exists: true } });
  out.withArray = c.countDocuments({
    $or: [ { entrances: { $exists: true } }, { members: { $exists: true } } ]
  });
  out.nested = c.countDocuments({ "members.name": { $exists: true } });
  out.typeless = c.countDocuments({ type: { $exists: false } });
  var idx = c.getIndexes();
  out.indexes = idx.map(function (i) { return i.name; });
  out.sparse = idx.filter(function (i) {
    return i.sparse === true || i.partialFilterExpression !== undefined;
  }).map(function (i) { return i.name; });
  var info = db.getSiblingDB("__DB__").getCollectionInfos({ name: "__COLL__" });
  var opts = (info && info[0] && info[0].options) ? info[0].options : {};
  out.validator = opts.validator ? 1 : 0;
  out.validationAction = opts.validationAction || "";
} catch (e) {
  out.ok = 0;
  out.error = String(e.message || e);
}
print(JSON.stringify(out));
JSEOF
)
MONGO_EVAL="${MONGO_EVAL//__DB__/$MONGO_DB}"
MONGO_EVAL="${MONGO_EVAL//__COLL__/$MONGO_COLL}"

# Der Container-Befehl wird INS Override gelegt, nicht außen in `--command --` belassen.
# kubectl wendet das Override als JSON-Merge-Patch an, und darin wird das Array containers
# vollständig ersetzt: der außen gesetzte `--command` würde den Pod nicht erreichen, und statt mongosh würde
# der Standardprozess des Images starten — also die Datenbank selbst. Genauso ist es in check/lib.sh gemacht.
MONGO_SC="$(python3 - "$MONGO_URI" "$MONGO_EVAL" <<'PYEOF'
import json, sys
uri, script = sys.argv[1], sys.argv[2]
print(json.dumps({"spec": {
  "securityContext": {"runAsNonRoot": True, "runAsUser": 999,
                      "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "mongo-check", "image": "mongo:8.0", "stdin": True,
                  "securityContext": {"allowPrivilegeEscalation": False,
                                      "capabilities": {"drop": ["ALL"]}},
                  "command": ["mongosh", "--quiet", uri, "--eval", script]}]}}))
PYEOF
)"

SUMMARY="$(kubectl run "mongo-check" --rm -i --restart=Never --quiet \
  --pod-running-timeout=90s --overrides="$MONGO_SC" \
  --image=mongo:8.0 </dev/null 2>/dev/null | tr -d '\r' | grep '^{' | tail -1)"

# Ein Feld aus der JSON-Zeile herausholen, die mongosh ausgegeben hat. Listen werden mit
# Komma zusammengefügt, damit man sie dem Teilnehmer so wie sie sind zeigen kann.
mget() {
  printf '%s' "$SUMMARY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if v is None:
    sys.exit(1)
print(v if not isinstance(v, list) else ", ".join(str(x) for x in v))
' "$1" 2>/dev/null
}

# Dasselbe, aber für Zahlen: Jeder unerwartete Wert wird zu 0, sonst würde der Vergleich
# unten mit einem Arithmetikfehler abbrechen statt mit einem klaren FAIL.
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# Wenn es überhaupt keine Antwort gibt oder mongosh einen Fehler meldete — gibt es nichts mehr zu prüfen.
# Eine Ablehnung der Authentifizierung wird von anderen Fehlern getrennt: Sie hat ihre eigene häufige Ursache —
# ein vergessenes authSource=admin, und der Hinweis sollte genau darauf führen.
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB hat die Zugangsdaten des Benutzers ${MONGO_USER} nicht akzeptiert" \
           "prüfe das Passwort und dass die Verbindungszeichenkette authSource=admin enthält: der Benutzer ist in der Datenbank admin angelegt, die Rechte aber in ${MONGO_DB} vergeben" ;;
    *)
      fail "die Abfrage an die Datenbank ${MONGO_DB} konnte nicht ausgeführt werden${ERR:+: $ERR}" \
           "prüfe manuell: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "die Verbindung zur Datenbank ${MONGO_DB} als Benutzer ${MONGO_USER} funktioniert"

# --- 2. Dokumente sind vorhanden --------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "Dokumente in der Sammlung ${MONGO_COLL}: ${TOTAL}"
else
  fail "die Sammlung ${MONGO_COLL} hat nur ${TOTAL} Dokumente, erwartet wurden mindestens vier" \
       "lade die Ausweise: mo < passes.js (die Aufschlüsselung der Datei steht in der README)"
fi

# --- 3. die Formen sind tatsächlich verschieden -----------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "die Sammlung hat ${TYPES} verschiedene Ausweistypen"
else
  fail "nur ${TYPES} verschiedene Ausweistypen, erwartet wurden vier" \
       "prüfe, dass passes.js vollständig geladen wurde: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "es gibt Dokumente mit einem verschachtelten Objekt (car.plate): ${WITH_CAR}"
else
  fail "kein einziges Dokument mit einem verschachtelten car-Objekt" \
       "der Auto-Ausweis wurde nicht geladen; wiederhole mo < passes.js"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "es gibt Dokumente mit Listen (entrances und members): ${WITH_ARRAY}"
else
  fail "Dokumente mit Listen ${WITH_ARRAY}, erwartet wurden mindestens zwei" \
       "der Wochen- und der Gruppen-Ausweis wurden nicht geladen; wiederhole mo < passes.js"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "die Suche in eine Objektliste hinein (members.name) findet Dokumente"
else
  fail "die Suche nach members.name fand nichts" \
       "der Gruppen-Ausweis mit einer Teilnehmerliste wurde nicht geladen; wiederhole mo < passes.js"
fi

evidence "Zusammensetzung der Sammlung" "Dokumente: ${TOTAL}
verschiedene Ausweistypen: ${TYPES}
mit verschachteltem car-Objekt: ${WITH_CAR}
mit Listen: ${WITH_ARRAY}"

# --- 4. Index auf ein seltenes Feld -----------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "ein dünn besetzter (oder partieller) Index ist gebaut: ${SPARSE}"
  evidence "Indizes der Sammlung" "alle: ${IDX}
dünn besetzt: ${SPARSE}"
else
  fail "es gibt keinen dünn besetzten Index — die Suche nach dem Kennzeichen läuft als vollständiger Scan" \
       "erstelle ihn: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "Indizes der Sammlung" "alle: ${IDX}"
fi

# --- 5. Schema-Validator ist eingeschaltet ----------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "der Schema-Validator ist eingeschaltet (Aktion bei Verstoß: ${ACTION:-Standard})"
  if [ "$ACTION" = "warn" ]; then
    warn "der Validator warnt nur, akzeptiert die Dokumente aber" \
         "eine Produktivsammlung braucht validationAction: error"
  fi
else
  fail "der Schema-Validator ist nicht eingeschaltet — ein Tippfehler im Feldnamen würde stillschweigend durchgehen" \
       "schalte ihn ein: mo < validator.js (siehe die Durchsprache des vorhersehbaren Fehlschlags in der README)"
fi

# --- 6. beschädigte Dokumente entfernt --------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "es sind keine Dokumente ohne Feld type mehr übrig"
else
  fail "die Sammlung hat ${TYPELESS} Dokumente ohne Feld type — die Sicherheit wird sie nicht sehen" \
       "finde und entferne sie: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish gibt das Fazit aus und legt das Bericht-Artefakt in einer Datei ab; der Rückgabecode ist ungleich null,
# wenn mindestens eine Prüfung fehlgeschlagen ist.
finish
