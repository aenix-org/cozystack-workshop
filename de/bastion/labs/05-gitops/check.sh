#!/usr/bin/env bash
# Prüfung für Lab 5: Der Cluster-Zustand kommt aus Git und wird durch Reconciliation gehalten.
#
# Läuft gegen Ihren `lab`-Cluster, aus dem Lab-Ordner, von Ihnen selbst:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# Ändert nichts — es schaut nur und gibt einen Bericht aus: was geprüft wurde, was bestanden hat,
# was nicht, und die angehängten Belege.
#
# Wir prüfen nicht „Flux ist installiert", sondern „der Mechanismus funktioniert": die Quelle wird gelesen, das
# Angewendete gehört Flux, der Dienst antwortet, die Reconciliation ist nicht abgeschaltet. Ein installiertes,
# aber pausiertes Flux ist der häufigste Weg, das Lab zu bestehen und seinen Sinn zu verfehlen.

LAB_NAME="05-gitops"
LAB_TITLE="Lab 5 · Infrastruktur in Git"
# Gemeinsame Testumgebung aller Labs: liefert ok / fail / warn / evidence / finish und die
# Umgebungsprüfungen. Der Pfad wird relativ zum Speicherort dieser Datei aufgelöst, sodass das Skript
# aus jedem Ordner ausgeführt werden kann.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne Datei für den Cluster-Zugang gibt es nichts zu prüfen — sofort mit klarem Grund beenden.
need_kubeconfig

# Die Namen, die dieses Lab erstellt. An einer Stelle gesammelt: hat ein Teilnehmer die Objekte
# anders benannt, hier bearbeiten statt im ganzen Skript nach Namen zu suchen.
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# Ein Feld eines Objekts lesen, ohne zu scheitern, wenn Objekt oder CRD fehlt.
kget() { kubectl get "$@" 2>/dev/null; }

# --- Flux-Dienste ----------------------------------------------------------
# Wir schauen nicht auf „Pods existieren", sondern auf „mindestens eine Replica ist Ready": ein Pod kann in
# Pending hängen, ohne Speicher auf dem Knoten, und trotzdem in der get-pods-Ausgabe erscheinen.
# Beide Dienste sind erforderlich und teilen sich die Arbeit: source-controller lädt das Repository herunter,
# kustomize-controller wendet das Heruntergeladene an. Ohne den zweiten erreicht nichts den Cluster.
if ! kget namespace flux-system >/dev/null; then
  fail "im Cluster gibt es keinen Namespace flux-system" \
       "Flux ist nicht installiert: flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "Flux-Dienste laufen: source-controller und kustomize-controller"
    evidence "Flux-Pods" "$(kget pods -n flux-system -o wide)"
  else
    fail "Flux-Dienste laufen nicht:${FLUX_BAD}" \
         "siehe kubectl get pods -n flux-system; auf einem kleinen Knoten kann ihnen der Speicher fehlen"
  fi
fi

# --- Quelle: GitRepository --------------------------------------------------
# Drei verschiedene Ausgänge, die man nicht verwechseln darf: das Objekt existiert gar nicht;
# das Objekt existiert, enthält aber noch eine Platzhalter-Adresse; das Objekt existiert mit echter Adresse,
# aber Flux konnte das Repository nicht lesen. Der Rat ist jeweils anders, deshalb sind auch die Zweige anders.
#
# Das Erfolgssignal nehmen wir aus status.conditions — das ist, was Flux selbst über sich meldet,
# nachdem es versucht hat, Git zu erreichen, und nicht unsere Vermutung anhand der Existenz des Objekts.
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "im Cluster gibt es keinen Typ GitRepository" \
       "Flux ist nicht installiert oder ohne source-controller installiert"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "kein GitRepository namens ${GITREPO} in flux-system gefunden" \
         "wenden Sie flux/gitrepository.yaml mit eingetragener Adresse Ihres Repositorys an"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "im GitRepository steht noch eine Platzhalter-Adresse" \
         "öffnen Sie flux/gitrepository.yaml und tragen Sie die Adresse Ihres eigenen GitHub-Repositorys ein"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux liest Ihr Repository: ${GR_URL}"
    evidence "Quelle in Git" "url: ${GR_URL}
revision: ${GR_REV:-unbekannt}"
  else
    fail "Flux kann das Repository ${GR_URL} nicht lesen" \
         "siehe flux get sources git; meist ist es ein Tippfehler in der Adresse, ein privates Repository oder ein anderer Branch"
    evidence "Quellenfehler" "${GR_MSG:-keine Meldung}"
  fi
fi

# --- Anwenden: Kustomization ------------------------------------------------
# Hier prüfen wir nicht die Tatsache des Anwendens, sondern drei Eigenschaften des Mechanismus, ohne die
# das Lab seinen Sinn verliert: die angewendete Revision stimmt mit Git überein, die Reconciliation ist nicht pausiert und
# das Löschen dessen, was aus dem Repository verschwunden ist, ist aktiviert.
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "im Cluster gibt es keinen Typ Kustomization" \
       "Flux wurde ohne kustomize-controller installiert — mit beiden Komponenten neu installieren"
else
  KS_READY="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  KS_MSG="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  KS_REV="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.status.lastAppliedRevision}')"
  KS_SUSPEND="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.suspend}')"
  KS_PRUNE="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.prune}')"
  KS_INTERVAL="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.interval}')"

  if [ -z "$KS_REV" ] && [ -z "$KS_READY" ]; then
    fail "kein Kustomization namens ${KUSTOMIZATION} in flux-system gefunden" \
         "wenden Sie flux/kustomization.yaml an"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux hat den Zustand aus Git angewendet, Revision ${KS_REV}"
    evidence "Angewendete Revision" "$KS_REV"
  else
    fail "Flux konnte den Zustand aus Git nicht anwenden" \
         "siehe flux get kustomizations und kubectl describe kustomization ${KUSTOMIZATION} -n flux-system"
    evidence "Anwendungsfehler" "${KS_MSG:-keine Meldung}"
  fi

  # Ein pausiertes Flux sieht installiert aus und tut nichts. Das ist der Hauptweg, das
  # Lab zu „bestehen", ohne einen einzigen seiner Vorteile zu erhalten.
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "die Reconciliation ist pausiert (suspend: true) — Flux überwacht den Cluster nicht" \
         "schalten Sie sie wieder ein: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "die Reconciliation ist aktiv: Abweichungen von Git werden von selbst korrigiert, Intervall ${KS_INTERVAL:-Standard}"
  fi

  # Das ist ein warn, kein fail: ohne prune wird der Cluster trotzdem aus Git verwaltet, das Lab ist bestanden.
  # Aber die Beschreibung wird einseitig — das Löschen einer Datei löscht nichts im Cluster.
  if [ "$KS_PRUNE" = "true" ]; then
    ok "das Löschen dessen, was aus Git verschwunden ist (prune), ist aktiviert"
  else
    warn "prune ist aus — was aus dem Repository entfernt wurde, läuft im Cluster weiter" \
         "setzen Sie prune: true in flux/kustomization.yaml, sonst beschreibt Git nur die Hälfte des Zustands"
  fi
fi

# --- Objekte im Cluster gehören Flux, nicht von Hand angewendet -------------
# Das ist die zentrale Prüfung des Labs, und es geht um Herkunft, nicht um Vorhandensein. Die Anwendung
# ist in beiden Fällen im Cluster: wenn Flux sie gebracht hat und wenn der Teilnehmer dieselben
# Dateien von Hand über kubectl apply angewendet hat. Von außen nicht zu unterscheiden — das Deployment ist identisch.
# Das Owner-Label unterscheidet sie: nur kustomize-controller setzt es, wenn es den
# Repository-Inhalt anwendet. Ein von Hand angewendetes Objekt erhält dieses Label nicht.
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "im Namespace ${NS_APP} gibt es keine Anwendung passes" \
       "legen Sie app/*.yaml in den Ordner apps Ihres Repositorys, pushen Sie und warten Sie auf die Reconciliation"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "die Anwendung im Cluster gehört Flux, nicht von Hand angewendet"
else
  fail "die Anwendung passes existiert, aber Flux hat sie nicht erstellt" \
       "entfernen Sie sie (kubectl delete ns ${NS_APP}) und lassen Sie Flux sie erneut aus Git ausrollen"
fi

# --- die Anwendung antwortet tatsächlich ------------------------------------
# Ein Objekt im Cluster und ein funktionierender Dienst sind verschiedene Dinge: ein Deployment kann erstellt sein,
# während Pods in einer Schleife abstürzen. Deshalb gehen wir in den Cluster hinein und fragen den Dienst über seinen
# internen Namen ab — denselben Weg, den benachbarte Anwendungen nutzen würden, um ihn zu erreichen.
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'Пропуск'; then
  ok "der Dienst «Пропуск» antwortet über HTTP im Cluster (laufende Replicas: ${PODS_READY})"
else
  fail "der Dienst «Пропуск» antwortet nicht unter passes.${NS_APP}.svc.cluster.local" \
       "siehe kubectl get pods -n ${NS_APP} und kubectl logs -n ${NS_APP} deploy/passes"
fi

# Der Pod-Name auf der Seite muss mit einer wirklich laufenden Replica übereinstimmen: das zeigt,
# dass die Antwort von genau dem Pod kommt, den wir im Cluster sehen, und nicht eine zwischengespeicherte
# Antwort oder ein anderer Dienst, der zufällig denselben Namen bekommen hat. Eine Nichtübereinstimmung ist
# ein warn, kein fail: die Replica kann zwischen zwei Anfragen neu erstellt worden sein, und das ist nicht der Fehler des Teilnehmers.
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "die Seite wurde von einem wirklich existierenden Pod ${SERVED_POD} ausgeliefert"
  evidence "Dienst-Replicas" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "der Pod ${SERVED_POD} aus der Antwort wurde nicht unter den laufenden gefunden" \
       "höchstwahrscheinlich wurde die Replica zwischen zwei Anfragen neu erstellt — führen Sie die Prüfung erneut aus"
fi

# --- Änderungsverlauf in Ihrem Klon des Repositorys -------------------------
# Optionaler Teil: das Skript weiß nicht, wo der Klon liegt, bis man es ihm sagt.
# Geprüft wird hier die Methode des Rollbacks. Über kubectl rollout undo kehrt der Cluster ebenfalls
# zur vorherigen Version zurück, aber Git erfährt nichts davon, und die nächste Reconciliation bringt
# die schlechte Änderung zurück. Deshalb suchen wir im Verlauf nach einem revert — der Rollback wird dort gemacht, wo die
# Wahrheit lebt. Und wir prüfen, dass die im Cluster angewendete Revision mit Ihrem HEAD übereinstimmt:
# committen und das Pushen vergessen ist üblich, und von außen sieht es aus wie „Flux hängt".
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "der Repository-Verlauf wurde nicht geprüft: die Variable LAB_REPO ist nicht gesetzt" \
       "um auch ihn zu prüfen: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "in ${REPO} gibt es keinen Klon des Repositorys" \
       "geben Sie den Ordner an, in den Sie git clone gemacht haben"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "im Verlauf gibt es einen Rollback über git revert — die schlechte Änderung wurde dort rückgängig gemacht, wo die Wahrheit lebt"
    evidence "Änderungsverlauf" "$LOG"
  else
    fail "in den letzten Commits gibt es keinen revert" \
         "machen Sie die schlechte Änderung über git revert --no-edit HEAD rückgängig und pushen Sie, nicht über kubectl rollout undo"
  fi

  # Das im Cluster Angewendete muss mit dem letzten Commit im Branch übereinstimmen.
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "im Cluster läuft genau das, was in Ihrem Branch liegt (Commit ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "der Commit im Cluster (${KS_REV:-unbekannt}) unterscheidet sich vom lokalen HEAD (${HEAD_SHA})" \
         "prüfen Sie, dass lokale Commits gepusht sind (git push), und warten Sie das Reconciliation-Intervall ab"
  fi
fi

finish
