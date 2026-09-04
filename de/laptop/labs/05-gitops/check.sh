#!/usr/bin/env bash
# Prüfung für Labor 5: Der Cluster-Zustand kommt aus Git und wird durch Abgleich gehalten.
#
# Wird auf Ihrem `lab`-Cluster ausgeführt, aus dem Labor-Ordner, von Ihnen:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# Es ändert nichts — es schaut nur und druckt einen Bericht: was geprüft wurde, was bestanden hat,
# was nicht, und die beigefügten Nachweise.
#
# Wir prüfen nicht «Flux ist installiert», sondern «der Mechanismus funktioniert»: die Quelle wird gelesen, das Angewandte
# gehört Flux, der Dienst antwortet, der Abgleich ist nicht abgeschaltet. Ein installierter, aber
# angehaltener Flux ist der häufigste Weg, das Labor am Sinn vorbei zu bestehen.

LAB_NAME="05-gitops"
LAB_TITLE="Labor 5 · Infrastruktur in Git"
# Die gemeinsame Umgebung aller Labore: daraus stammen ok / fail / warn / evidence / finish und
# die Umgebungsprüfungen. Der Pfad wird vom Speicherort dieser Datei aus bestimmt, daher kann das Skript
# aus jedem Ordner ausgeführt werden.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne Cluster-Zugriffsdatei gibt es nichts zu prüfen — wir beenden sofort mit einem klaren Grund.
need_kubeconfig

# Die Namen, die das Labor erstellt. An einer Stelle gesammelt: wenn der Teilnehmer die Objekte
# anders benannt hat, hier korrigieren statt Namen im ganzen Skript zu suchen.
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# Ein Feld eines Objekts lesen, ohne zu scheitern, wenn das Objekt oder die CRD fehlt.
kget() { kubectl get "$@" 2>/dev/null; }

# --- Flux-Dienste -----------------------------------------------------------
# Wir schauen nicht «die Pods existieren», sondern «mindestens eine Replik ist im Zustand Ready»: ein Pod kann
# in Pending hängen, ohne Speicher auf dem Knoten, und trotzdem in der get-pods-Ausgabe erscheinen.
# Beide Dienste sind erforderlich und teilen sich die Arbeit: source-controller lädt das Repository herunter,
# kustomize-controller wendet das Heruntergeladene an. Ohne den zweiten gelangt nichts in den Cluster.
if ! kget namespace flux-system >/dev/null; then
  fail "der Cluster hat keinen flux-system-Namespace" \
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
         "siehe kubectl get pods -n flux-system; auf einem kleinen Knoten fehlt ihnen möglicherweise Speicher"
  fi
fi

# --- Quelle: GitRepository ------------------------------------------------
# Drei verschiedene Ausgänge, und man darf sie nicht verwechseln: das Objekt existiert gar nicht; das Objekt
# existiert, aber in ihm ist noch der Platzhalter-Adresse geblieben; das Objekt existiert mit einer echten
# Adresse, aber Flux konnte das Repository nicht lesen. Der Rat unterscheidet sich in jedem Fall, daher unterscheiden sich auch die Zweige.
#
# Das Erfolgssignal nehmen wir aus status.conditions — das ist, was Flux selbst über sich meldet
# nach dem Versuch, Git zu erreichen, und nicht unsere Vermutung aufgrund des Vorhandenseins des Objekts.
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "der Cluster hat keinen Typ GitRepository" \
       "Flux ist nicht installiert oder ohne source-controller installiert"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "kein GitRepository mit Namen ${GITREPO} in flux-system gefunden" \
         "wenden Sie flux/gitrepository.yaml an und setzen Sie die Adresse Ihres eigenen Repositorys ein"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "im GitRepository ist noch die Platzhalter-Adresse geblieben" \
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

# --- Anwendung: Kustomization ----------------------------------------------
# Hier wird nicht die Tatsache der Anwendung geprüft, sondern drei Eigenschaften des Mechanismus, ohne die das Labor
# seinen Sinn verliert: die angewandte Revision stimmt mit Git überein, der Abgleich ist nicht angehalten und
# das Löschen des aus dem Repository Verschwundenen ist aktiviert.
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "der Cluster hat keinen Typ Kustomization" \
       "Flux ist ohne kustomize-controller installiert — installieren Sie mit beiden Komponenten neu"
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
    fail "kein Kustomization mit Namen ${KUSTOMIZATION} in flux-system gefunden" \
         "wenden Sie flux/kustomization.yaml an"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux hat den Zustand aus Git angewandt, Revision ${KS_REV}"
    evidence "Angewandte Revision" "$KS_REV"
  else
    fail "Flux konnte den Zustand aus Git nicht anwenden" \
         "siehe flux get kustomizations und kubectl describe kustomization ${KUSTOMIZATION} -n flux-system"
    evidence "Anwendungsfehler" "${KS_MSG:-keine Meldung}"
  fi

  # Ein angehaltener Flux sieht installiert aus und tut nichts. Das ist der wichtigste
  # Weg, das Labor zu «bestehen», ohne einen einzigen seiner Vorteile zu erhalten.
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "der Abgleich ist angehalten (suspend: true) — Flux überwacht den Cluster nicht" \
         "schalten Sie ihn wieder ein: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "der Abgleich ist aktiv: eine Abweichung von Git wird von selbst korrigiert, Intervall ${KS_INTERVAL:-Standard}"
  fi

  # Das ist ein warn, kein fail: ohne prune wird der Cluster trotzdem aus Git verwaltet, das Labor ist bestanden.
  # Aber die Beschreibung wird einseitig — das Löschen einer Datei löscht nichts im Cluster.
  if [ "$KS_PRUNE" = "true" ]; then
    ok "das Löschen dessen, was aus Git verschwunden ist, ist aktiviert (prune)"
  else
    warn "prune ist aus — aus dem Repository Entferntes läuft weiter im Cluster" \
         "setzen Sie prune: true in flux/kustomization.yaml, sonst beschreibt Git den Zustand nur zur Hälfte"
  fi
fi

# --- die Objekte im Cluster gehören Flux und wurden nicht von Hand angewandt ---------
# Das ist die zentrale Prüfung des Labors, und es geht um die Herkunft, nicht um das Vorhandensein. Die Anwendung
# ist in beiden Fällen im Cluster: sowohl wenn Flux sie hereingebracht hat, als auch wenn der Teilnehmer
# dieselben Dateien von Hand über kubectl apply angewandt hat. Äußerlich nicht zu unterscheiden — das Deployment ist identisch.
# Es unterscheidet das Eigentümer-Label: nur kustomize-controller setzt es, wenn es
# den Inhalt des Repositorys anwendet. Ein von Hand angewandtes Objekt erhält dieses Label nicht.
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "im Namespace ${NS_APP} gibt es keine passes-Anwendung" \
       "legen Sie app/*.yaml in den apps-Ordner Ihres Repositorys, pushen Sie und warten Sie auf den Abgleich"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "die Anwendung im Cluster gehört Flux und wurde nicht von Hand angewandt"
else
  fail "die passes-Anwendung existiert, aber nicht Flux hat sie erstellt" \
       "entfernen Sie sie (kubectl delete ns ${NS_APP}) und lassen Sie Flux sie erneut aus Git bereitstellen"
fi

# --- die Anwendung antwortet tatsächlich --------------------------------------
# Ein Objekt im Cluster und ein funktionierender Dienst sind verschiedene Dinge: ein Deployment kann erstellt sein,
# während die Pods in einer Schleife abstürzen. Deshalb gehen wir in den Cluster hinein und fragen den Dienst über seinen
# internen Namen ab — auf demselben Weg, über den ihn benachbarte Anwendungen erreichen würden.
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'Пропуск'; then
  ok "der Dienst «Пропуск» antwortet über HTTP innerhalb des Clusters (laufende Repliken: ${PODS_READY})"
else
  fail "der Dienst «Пропуск» antwortet nicht unter passes.${NS_APP}.svc.cluster.local" \
       "siehe kubectl get pods -n ${NS_APP} und kubectl logs -n ${NS_APP} deploy/passes"
fi

# Der Pod-Name auf der Seite muss mit einer wirklich laufenden Replik übereinstimmen: so ist erkennbar,
# dass genau der Pod antwortet, den wir im Cluster sehen, und nicht eine zwischengespeicherte
# Antwort oder ein fremder Dienst, der zufällig denselben Namen belegt hat. Eine Abweichung ist ein warn, kein
# fail: die Replik könnte zwischen den zwei Anfragen neu erstellt worden sein, und das ist nicht die Schuld des Teilnehmers.
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "die Seite wurde von einem wirklich existierenden Pod ${SERVED_POD} ausgeliefert"
  evidence "Dienst-Repliken" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "der Pod ${SERVED_POD} aus der Antwort wurde nicht unter den laufenden gefunden" \
       "höchstwahrscheinlich wurde die Replik zwischen den zwei Anfragen neu erstellt — führen Sie die Prüfung erneut aus"
fi

# --- die Änderungshistorie in Ihrem Klon des Repositorys ----------------------------
# Ein optionaler Teil: das Skript weiß nicht, wo der Klon liegt, bis man es ihm sagt.
# Geprüft wird hier die Art des Rückgängigmachens. Mit kubectl rollout undo kehrt der Cluster ebenfalls
# zur vorherigen Version zurück, aber Git erfährt davon nichts, und der nächste Abgleich bringt die schlechte
# Änderung wieder zurück. Deshalb suchen wir in der Historie nach einem revert — das Rückgängigmachen wird dort gemacht, wo die
# Wahrheit lebt. Und wir prüfen, dass die im Cluster angewandte Revision mit Ihrem HEAD übereinstimmt:
# committen und das Pushen vergessen ist alltäglich, und von außen sieht es aus wie «Flux hängt».
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "die Repository-Historie wurde nicht geprüft: die Variable LAB_REPO ist nicht gesetzt" \
       "um auch sie zu prüfen: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "in ${REPO} gibt es keinen Klon des Repositorys" \
       "geben Sie den Ordner an, in den Sie git clone gemacht haben"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "die Historie enthält ein Rückgängigmachen über git revert — die schlechte Änderung wurde dort rückgängig gemacht, wo die Wahrheit lebt"
    evidence "Änderungshistorie" "$LOG"
  else
    fail "in den letzten Commits gibt es kein einziges revert" \
         "machen Sie die schlechte Änderung mit git revert --no-edit HEAD rückgängig und pushen Sie, nicht mit kubectl rollout undo"
  fi

  # Das im Cluster Angewandte muss mit dem letzten Commit im Branch übereinstimmen.
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "im Cluster läuft genau das, was in Ihrem Branch liegt (Commit ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "der Commit im Cluster (${KS_REV:-unbekannt}) unterscheidet sich vom lokalen HEAD (${HEAD_SHA})" \
         "prüfen Sie, dass die lokalen Commits gepusht wurden (git push), und warten Sie das Abgleichsintervall ab"
  fi
fi

finish
