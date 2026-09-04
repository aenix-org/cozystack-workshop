# Lab 5 · Infrastruktur in Git

| | |
|---|---|
| **Zeit** | 40 Minuten |
| **Was es zeigt** | Der Cluster bringt sich selbst in den Zustand, der in Git steht, und hält ihn |
| **Was Sie brauchen** | Der Cluster aus Lab 0, `kubectl`, `git`, ein GitHub-Konto, die `flux`-CLI |

## Warum das wichtig ist

Das Üben ist vorbei. Ab hier ist es eine echte Aufgabe.

Das Unternehmen möchte einen internen Dienst namens **„Passes“**: Ein Mitarbeiter bestellt über eine mobile App einen Besucherausweis, der Sicherheitsdienst sieht die Liste am Empfang, und das Management schaut sich einmal im Monat einen Bericht an. Sie sind im Plattform-Team, und diesen Dienst auszuliefern ist Ihre Aufgabe.

Hinter dem Dienst werden mehrere Teams stehen, und im Plattform-Team sind Sie zu dritt. Und genau hier beginnt der Grund, warum dieses Lab im praktischen Teil an erster Stelle steht.

**Was passiert, wenn es drei Administratoren gibt.** Jemand hat die App über das Dashboard hochgezogen. Jemand hat die Limits über `kubectl edit` angepasst, weil es mitten in der Nacht war und alles brannte. Jemand hat am Freitag die Anzahl der Kopien geändert und es bis Montag vergessen. Einen Monat später kann niemand zwei Fragen beantworten: **warum diese Einstellung so ist, wie sie ist** und **wie sie sein sollte**. Und wenn alles zusammenbricht, stellt sich heraus, dass es nichts gibt, woraus man wiederherstellen könnte — der Zustand lebte nur im Kopf des Clusters und verschwand zusammen mit dem Cluster.

Das Heilmittel dagegen ist keine Richtlinie, und es ist auch kein „einigen wir uns alle darauf, nichts von Hand anzufassen“. Das Heilmittel besteht darin, das Anfassen von Hand **sinnlos** zu machen: Der Cluster stellt den alten Zustand wieder her. Genau das schalten wir heute ein.

## Kleines Glossar

| Begriff | Was es ist | Wie… aber |
|---|---|---|
| **Repository** | Eine Menge von Dateien zusammen mit der vollständigen Historie ihrer Änderungen: was sich geändert hat, wer es geändert hat und warum | **Ein Ordner mit Vorlagen auf einem gemeinsamen Laufwerk**, aber jeder hat seine eigene vollständige Kopie statt einer einzigen für alle |
| **GitOps** | Ein Ansatz: Der gewünschte Zustand lebt in Git, und ein im Cluster laufender Agent überträgt ihn dorthin | **vRealize Automation mit einem Blueprint**, aber keine einmalige Anwendung — ein kontinuierlicher Abgleich |
| **Flux** | Genau dieser Agent. Er läuft innerhalb des Clusters | **Ein geplanter Agent/Skript**, aber nicht „anwenden und vergessen“: Er prüft jede Minute und behebt jede Abweichung |
| **Kustomization** | Ein Objekt im Cluster: was genau aus dem Repository anzuwenden ist | **Ein Deployment-Job**, aber verwechseln Sie es nicht mit dem `kustomize`-Werkzeug — gleicher Name, andere Bedeutung |

Die übrigen Begriffe dieses Labs — Git, Commit, Branch, Pull Request, Reconciliation, Drift, GitRepository, Prune — werden nach und nach eingeführt, an dem Schritt, an dem sie zuerst gebraucht werden. Sie müssen sie sich jetzt nicht merken: ohne die Handlung bleiben sie ohnehin nicht hängen.

<details>
<summary><b>Falls Sie die ganze Liste auf einmal sehen möchten</b></summary>

| Begriff | Was es ist | Wie… aber |
|---|---|---|
| **Git** | Ein Speicher für Textdateien mit der vollständigen Änderungshistorie | **Ein Archiv von Konfigurationen + ein Änderungsprotokoll**, aber es speichert nicht Kopien von Dateien, sondern jede Änderung einzeln, mit ihrem Autor und Grund |
| **Commit** | Eine gespeicherte Änderung: was, wer, warum | **Ein Eintrag in einem Änderungsprotokoll**, aber es speichert den geänderten Text selbst, nicht nur den Hinweis, dass eine Änderung stattfand |
| **Branch** | Eine parallele Änderungslinie | keine direkte Analogie; Sie brauchen ihn, um eine Änderung vorzubereiten, ohne die funktionierende Version anzufassen |
| **Pull Request** | Ein Vorschlag, einen Branch zu mergen, den jemand prüft, bevor er angewendet wird | **Das Genehmigen eines Antrags**, aber die Diskussion dreht sich um konkrete Konfigurationszeilen, nicht um den allgemeinen Sinn des Antrags |
| **Reconciliation** | Die Schleife: den gewünschten Zustand lesen → mit dem tatsächlichen Zustand vergleichen → ihn korrigieren | **Die DRS-Logik, die den Cluster in Richtung eines Zielzustands zieht**, aber abgeglichen wird nicht die Platzierung von Maschinen — sondern alles, was beschrieben wurde |
| **Drift** | Eine Abweichung zwischen Ist und Beschreibung | **Eine Änderung außerhalb der Vorlage**, aber hier wird der Drift nicht „in einem Compliance-Bericht vermerkt“ — er wird stillschweigend entfernt |
| **GitRepository** | Ein Objekt im Cluster: woher der Zustand genommen wird | **Die Einstellung für eine Vorlagenquelle**, aber die Quelle wird von selbst nach Zeitplan abgefragt, nicht in dem Moment, in dem jemand auf „Deploy“ klickt |
| **Prune** | Der Modus „lösche aus dem Cluster, was aus Git verschwunden ist“ | keine direkte Analogie; ohne ihn löscht das Löschen einer Datei aus dem Repository nichts im Cluster |

</details>

## Was im Lab-Ordner liegt

Alle Dateien gehören bereits Ihnen — Sie haben sie zusammen mit dem Repository übernommen. Es gibt nichts zu erstellen oder erneut abzutippen: Wo immer unten `kubectl apply -f name.yaml` steht, stammt die Datei von hier.

```bash
# Ab hier laufen alle Befehle aus diesem Ordner: Die Pfade in `kubectl apply -f` sind relativ dazu.
cd labs/05-gitops
```

| Datei | Was es ist | Wann es nützlich ist |
|---|---|---|
| `app/` | Was im Cluster landen soll: der Namespace und der Dienst „Passes“ selbst | Sie legen es in Ihr eigenes Git-Repository |
| `flux/` | Zwei Beschreibungen für Flux: woher das Repository zu nehmen ist und was daraus anzuwenden ist | Sie wenden es auf Ihren eigenen `lab`-Cluster an |
| `check.sh` | Eine Prüfung, dass der Cluster die Änderung von selbst aus Git geholt hat | Sie führen es am Ende des Labs aus |

## Schritt 1. Das Repository einrichten

📍 **Wo:** im Browser, auf GitHub.

Erstellen Sie ein neues Repository:

| Feld | Wert | Warum |
|---|---|---|
| Name | `passes-gitops` | es macht klar, dass dies der Zustand des Dienstes ist, nicht sein Quellcode |
| Visibility | **Public** | damit Flux es ohne Schlüssel erreichen kann und Sie keine Zeit mit Zugriffsrechten verbringen |
| Add a README file | Kästchen ankreuzen | sonst ist das Repository leer, ohne Branch, und Flux findet nichts zum Lesen |

⚠️ **Ein öffentliches Repository ist hier eine bewusste Vereinfachung der Schulungs-Testumgebung.** In der Produktion ist das Repository privat, und Flux erreicht es über einen Deploy-Key. Das sind weitere zwanzig Minuten Herumbasteln mit SSH-Schlüsseln, und heute geht es um etwas anderes. Was dort leben wird — Manifeste ohne ein einziges Passwort — sehen Sie selbst: Passwörter gehören nicht in Git, und dafür gibt es ein eigenes Lab.

📍 **Wo:** auf Ihrem Laptop.

Holen Sie das Repository auf Ihre Maschine:

```bash
# clone = das Repository vollständig herunterladen, zusammen mit seiner gesamten Änderungshistorie. Sie erhalten
# nicht Zugriff auf einen gemeinsamen Ordner, sondern Ihre eigene vollständige Kopie auf der Festplatte: Sie können offline damit arbeiten.
# IHR-LOGIN durch Ihren eigenen GitHub-Login ersetzen, sonst geht der Befehl zu einem fremden Repository.
git clone https://github.com/IHR-LOGIN/passes-gitops.git
# clone erstellt einen Ordner, der nach dem Repository benannt ist. Ab hier arbeiten wir darin.
cd passes-gitops
```

## Schritt 2. Den Dienst „Passes“ ins Repository legen

📍 **Wo:** auf Ihrem Laptop.

Im Ordner dieses Labs liegen zwei Dateien: `app/namespace.yaml` und `app/passes.yaml`. Kopieren Sie sie in Ihr Repository, in den Ordner `apps`:

```bash
# apps — der Ordner, aus dem Flux die Beschreibungen holt. Wir haben den Namen gewählt, und es ist genau
# derselbe, der in der Flux-Konfiguration genannt ist, es gibt also keinen Grund, ihn ohne Anlass zu ändern.
#   -p  es nicht als Fehler behandeln, wenn der Ordner bereits existiert
mkdir -p apps
# Beide Dateien in Ihr eigenes Repository kopieren. Ersetzen Sie `/path/to/` durch den Ort, an dem Sie
# das Labs-Repository geklont haben; `*.yaml` nimmt beide Dateien auf einmal.
cp /path/to/labs/05-gitops/app/*.yaml apps/
```

Bevor Sie sie abschicken, gehen wir durch, was Sie hineinlegen.

<details>
<summary><b>Genauer betrachtet: was in namespace.yaml und passes.yaml steckt</b></summary>

### `namespace.yaml` — ein eigener Namespace

```yaml
kind: Namespace
metadata:
  name: passes
```

Ein Namespace ist eine logische Unterteilung innerhalb eines einzelnen Clusters. Die nächste Analogie in vSphere ist ein Ordner im vCenter-Baum oder ein Resource Pool: dieselben Ressourcen, aber ein eigener Geltungsbereich, eigene Rechte und eigene Quotas.

Warum in Git zusammen mit der Anwendung ablegen, statt ihn von Hand zu erstellen: Wenn der Dienst irgendwann das Repository verlässt, entfernt Flux auch den Namespace. Es bleibt keine leere Unterteilung zurück, bei der sich sechs Monate später niemand erinnert, warum sie angelegt wurde.

### `passes.yaml` — der Dienst selbst

Vier Objekte, getrennt durch eine `---`-Zeile.

**Das erste — eine `ConfigMap` mit der nginx-Konfiguration.** Eine `ConfigMap` legt eine Textdatei getrennt von der Anwendung in den Cluster, und diese Datei wird dann im Container eingehängt. Der Sinn ist, die Konfiguration zu ändern, ohne das Image neu zu bauen.

Darin steckt eine gewöhnliche nginx-Konfiguration. Eine Zeile verdient Aufmerksamkeit:

```
sub_filter '__POD__' '$hostname';
```

Das sagt nginx: In der Seite, die es ausliefert, ersetze den Text `__POD__` durch den Namen der Maschine, auf der es läuft. Innerhalb eines Pods ist der Maschinenname der Name des Pods selbst. So meldet die Seite, welche Kopie sie ausgeliefert hat. Später sehen Sie an diesem Namen, dass es nun zwei Kopien gibt.

**Das zweite — eine `ConfigMap` mit der Seite.** Vorerst ist es ein Platzhalter: Die echte Anwendung taucht im nächsten Lab auf, und heute zählt nicht, was der Dienst anzeigt, sondern **woher er** im Cluster **kam**.

**Das dritte — ein `Deployment`.** Die Beschreibung der Anwendung: welches Image, wie viele Kopien, wie die Bereitschaft zu prüfen ist.

```yaml
spec:
  replicas: 1
```

Wie viele Kopien am Laufen gehalten werden sollen. Achten Sie auf die Formulierung: nicht „eine starten“, sondern „eine halten“. Das ist die Zahl, die wir über Git ändern und dabei beobachten, was passiert.

```yaml
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
```

Die Bereitschaftsprüfung: Der Cluster klopft an diese Adresse und schickt einer Kopie keinen Traffic, bis er eine Antwort erhält. Flux braucht sie ebenfalls — wir werden es bitten, auf die Bereitschaft zu warten, statt gleich nach dem Anwenden Erfolg zu melden.

**Das vierte — ein `Service`.** Ein dauerhafter Name, der vor allen Kopien steht. Die Verbindung zwischen dem `Service` und den Pods ist keine Adressliste, sondern die Bedingung `selector: app: passes`, also „alle Pods mit diesem Label“. Eine neue Kopie mit dem Label ist aufgetaucht — sie wird automatisch in den Lastausgleich aufgenommen.

Keines der vier Objekte enthält ein Passwort, einen Schlüssel oder einen Token. Das ist kein Zufall: Alles, was in Git gelangt, gelangt für immer dorthin — die Historie lässt sich umschreiben, aber jeder, der es geschafft hat, es zu klonen, behält die alte Kopie. Secrets haben hier nichts zu suchen; dafür gibt es einen eigenen Mechanismus und ein eigenes Lab.

</details>

Schicken Sie es zu GitHub. Git merkt sich nicht wahllos alles, sondern das, was ihm ausdrücklich gezeigt wurde — deshalb gibt es drei Befehle, von denen jeder seine eigene Aufgabe hat:

```bash
# add = die Dateien markieren, die in den nächsten Historieneintrag kommen.
git add apps
# commit = das Markierte als einen Eintrag speichern: Inhalt, Autor, Zeit und Grund.
#   -m "..."  genau dieser Grund. Er bleibt für immer in der Historie, und Menschen werden ihn lesen.
# Der Commit lebt vorerst nur auf Ihrem Laptop — er ist noch nicht in GitHub.
git commit -m "add passes service v1"
# push = die angesammelten Commits zu GitHub schicken. Bis zu diesem Befehl ändert sich dort nichts.
git push
```

**Was Sie sehen sollten** — im Browser, auf der Repository-Seite, den Ordner `apps` mit zwei Dateien. Im Cluster hat sich unterdessen noch nichts geändert: Git weiß nichts vom Cluster.

## Schritt 3. Flux in Ihren Cluster installieren

📍 **Wo:** auf Ihrem Laptop.

Flux besteht aus mehreren Diensten innerhalb Ihres Clusters. Einer greift nach Git und lädt den Inhalt herunter, ein anderer wendet das Heruntergeladene auf den Cluster an und wacht über Abweichungen.

Der Cluster gehört Ihnen, und Sie sind sein vollständiger Administrator. Sie installieren es selbst; das Plattform-Team müssen Sie nicht fragen.

Zuerst das `flux`-Kommandozeilenwerkzeug. Es lebt auf Ihrem Laptop, nicht im Cluster: Sie verwenden es, um die Dienste zu installieren und sie danach nach ihrem Zustand zu fragen.

macOS:

```bash
# Homebrew nimmt die Formel aus dem Repository des Flux-Projekts und legt eine ausführbare Datei ab.
brew install fluxcd/tap/flux
```

Linux:

```bash
# Das Skript von der Flux-Seite erkennt Ihre Architektur und legt die Datei in /usr/local/bin ab.
#   -s          curl arbeitet still, ohne Fortschrittsanzeige
#   | sudo bash der heruntergeladene Text wird sofort mit Administratorrechten ausgeführt — sie sind
#               nötig wegen des Schreibens in einen Systemordner
curl -s https://fluxcd.io/install.sh | sudo bash
```

Windows (PowerShell, falls Chocolatey installiert ist):

```powershell
# choco — ein Drittanbieter-Paketmanager für Windows; er installiert dieselbe einzelne flux.exe-Datei.
choco install flux
```

Jetzt installieren wir die Dienste selbst in den Cluster:

```bash
# Die Zugriffsdatei setzen: Der Befehl unten erstellt Objekte im Cluster, und es kommt darauf an, in welchem.
export KUBECONFIG=~/lab.kubeconfig
# flux install richtet im Cluster einen `flux-system`-Namespace ein und rollt die Dienste dorthin aus.
#   --components=...  welche genau zu installieren sind:
#     source-controller     greift nach Git und hält eine frische Kopie des Repositorys
#     kustomize-controller  wendet das Heruntergeladene auf den Cluster an und wacht über Abweichungen
flux install --components=source-controller,kustomize-controller
```

⚠️ **Prüfen Sie, wohin `KUBECONFIG` zeigt, bevor Sie Enter drücken.** Wir installieren Flux in Ihren eigenen `lab`-Cluster, nicht in den, aus dem er Ihnen übergeben wurde. Im Zweifel — `kubectl get nodes` sollte einen Node mit einem Namen wie `kubernetes-lab-md0-...` zeigen.

**Was Sie sehen sollten** — eine Auflistung dessen, was erstellt wird, und am Ende eine Zeile über eine erfolgreiche Installation:

```
✔ install finished
```

Wir installieren nur zwei der vier Dienste. Der vollständige Flux-Satz kann auch Helm-Charts ausrollen und Benachrichtigungen an Messenger senden — heute wird das nicht gebraucht, und wir haben nur einen Node mit nicht viel Speicher darauf.

Vergewissern Sie sich, dass die Dienste hochgekommen sind:

```bash
# -n flux-system — der Namespace, in dem sich Flux eingerichtet hat. Ohne dieses Flag schaut kubectl im
# default-Namespace und zeigt nichts.
kubectl get pods -n flux-system
```

**Was Sie sehen sollten** — zwei Zeilen im Zustand `Running`.

<details>
<summary><b>Falls die Installation der <code>flux</code>-CLI nicht geklappt hat</b></summary>

Genau dasselbe lässt sich mit einem gewöhnlichen Manifest installieren, ohne das Werkzeug:

```bash
# Derselbe Satz von Diensten, aber als fertige Beschreibung: -f akzeptiert nicht nur einen Pfad auf der Festplatte,
# sondern auch einen Link. kubectl lädt die Datei herunter und wendet ihren Inhalt an.
kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
```

Der Unterschied: So kommen alle vier Dienste hoch statt zwei. Das macht sich beim Speicher bemerkbar, aber das Lab geht trotzdem durch. Weiter im Text werden die `flux ...`-Befehle nur gebraucht, um den Zustand anzusehen — sie lassen sich durch `kubectl get gitrepository` und `kubectl get kustomization` ersetzen, die dasselbe zeigen, nur weniger übersichtlich.

</details>

## Schritt 4. Flux auf das Repository richten

📍 **Wo:** auf Ihrem Laptop.

Flux ist installiert, weiß aber noch nicht, wohin es gehen soll. Wir sagen es ihm, mit zwei Objekten.

Öffnen Sie `flux/gitrepository.yaml` aus dem Ordner dieses Labs und tragen Sie die Adresse **Ihres** Repositorys anstelle des Platzhalters `ERSETZEN-MICH` ein:

```yaml
  url: https://github.com/ERSETZEN-MICH/passes-gitops
```

<details>
<summary><b>Genauer betrachtet: was in gitrepository.yaml und kustomization.yaml steckt</b></summary>

### `GitRepository` — woher es zu nehmen ist

```yaml
kind: GitRepository
spec:
  interval: 1m
  url: https://github.com/ERSETZEN-MICH/passes-gitops
  ref:
    branch: main
```

Die einzige Aufgabe dieses Objekts ist, eine frische Kopie des Repositorys zu halten. Es wendet nichts auf den Cluster an, es lädt nur herunter.

`interval: 1m` — wie oft nach Updates gegangen wird. Eine Minute ist für das Lab gewählt, damit Sie nicht warten müssen. In der Produktion wird es üblicherweise auf ein bis fünf Minuten gesetzt, und eine sofortige Reaktion auf einen Push wird nicht durch Verkleinern des Intervalls erreicht, sondern mit einem Webhook: GitHub selbst klopft am Cluster an, wenn sich etwas geändert hat.

`ref: branch: main` — welcher Branch als Quelle der Wahrheit gilt. Alles, was in `main` gemergt wird, reist zum Cluster. Alles in anderen Branches nicht. Daher kommt die Review: Eine Änderung lebt zuerst in ihrem eigenen Branch, wo man sie ansehen kann, und erst das Mergen in `main` lässt sie wirksam werden.

### `Kustomization` — was anzuwenden ist

```yaml
kind: Kustomization
spec:
  interval: 1m
  path: ./apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: passes
  wait: true
```

`path: ./apps` — der Ordner innerhalb des Repositorys. Alles darin reist zum Cluster. Dateien daneben — zum Beispiel eine `README.md` im Wurzelverzeichnis — werden nicht angerührt.

`interval: 1m` bedeutet hier nicht dasselbe wie in `GitRepository`. Dort heißt es „wie oft herunterladen“. Hier heißt es **wie oft der tatsächliche Zustand des Clusters gegen den beschriebenen abgeglichen wird**. Selbst wenn sich in Git nichts geändert hat, prüft Flux einmal pro Minute, ob der Cluster der Beschreibung entspricht, und bringt ihn in Übereinstimmung. Genau daran werden wir uns etwas weiter im Lab verfangen.

`prune: true` — aus dem Cluster die Objekte löschen, die aus Git verschwunden sind. Ohne dies hört Git auf, eine vollständige Beschreibung zu sein: Sie löschen eine Datei aus dem Repository, aber das Objekt läuft weiter im Cluster, und sechs Monate später versteht niemand, woher es kam. Mit `prune` stimmen Beschreibung und Realität in beide Richtungen überein.

`wait: true` — nicht gleich nach dem Anwenden Erfolg melden, sondern warten, bis das Angewendete bereit ist. Der Unterschied ist genau derselbe wie zwischen „den Antrag eingereicht“ und „der Antrag ist erledigt“.

</details>

Wenden Sie beide an:

```bash
# -f zeigt auf einen Ordner, nicht auf eine Datei: alle Manifeste darin werden angewendet —
# sowohl GitRepository als auch Kustomization. Beide werden im flux-system-Namespace erstellt.
kubectl apply -f flux/
```

Sehen wir uns an, was dabei herauskam:

```bash
# Wir fragen Flux nach dem Abgleichszustand.
#   --watch  das Fenster belegt halten und die Zeile aktualisieren, während sich Dinge ändern
# READY: True bedeutet, dass der Inhalt des Repositorys den Cluster erreicht hat und angewendet wurde.
# REVISION — der Branch und die kurze Kennung des aktuell angewendeten Commits.
flux get kustomizations --watch
```

**Was Sie sehen sollten** — nach einigen Dutzend Sekunden der Zustand `Ready: True` und der Hash des angewendeten Commits:

```
NAME     REVISION            SUSPENDED  READY  MESSAGE
passes   main@sha1:a1b2c3d   False      True   Applied revision: main@sha1:a1b2c3d
```

Beenden Sie die Beobachtung mit `Ctrl+C` und sehen Sie sich an, was im Cluster aufgetaucht ist:

```bash
# all — eine Kurzform für die wichtigsten Objekttypen auf einmal: Pods, Deployment, Service und den Rest.
# Sie haben den `passes`-Namespace nicht von Hand erstellt: Er kam aus dem Repository zusammen mit der Anwendung.
kubectl get all -n passes
```

**Sie haben nichts von Hand angewendet.** Sie haben Text in GitHub gelegt, und der Cluster hat ihn von selbst geholt. Der Unterschied zwischen diesem Vorgehen und `kubectl apply -f` ist nicht die Bequemlichkeit — sondern dass es nun einen einzigen Ort gibt, an dem geschrieben steht, wie die Dinge sein sollen.

## Schritt 5. Die erste Änderung über `git push`

📍 **Wo:** auf Ihrem Laptop, im Repository-Ordner.

Eine Kopie reicht für den Dienst „Passes“ nicht: Der Sicherheitsdienst beobachtet die Liste rund um die Uhr, und ein Update der Anwendung sollte den Empfang nicht lahmlegen. Setzen wir zwei.

Früher hätten Sie `kubectl scale` ausgeführt. Jetzt — eine Änderung in der Datei.

Öffnen Sie `apps/passes.yaml` und ändern Sie:

```yaml
spec:
  replicas: 2
```

Schicken Sie es ab:

```bash
# Dieselben drei Schritte wie beim ersten Abschicken: die Datei markieren, mit einem Grund speichern, senden.
git add apps/passes.yaml
git commit -m "passes: two replicas so the gate does not go dark during rollout"
git push
```

Beobachten Sie nun den Cluster und warten Sie:

```bash
# -w = "beobachten und weiter anhängen": Das Fenster bleibt belegt, eine neue Zeile erscheint jedes Mal,
# wenn sich der Zustand der Kopien ändert. Beenden mit Ctrl+C.
kubectl get pods -n passes -w
```

**Was Sie sehen sollten** — innerhalb einer Minute erscheint eine zweite Kopie. Sie haben sie nicht erstellt.

Wollen Sie keine Minute warten — Sie können Flux bitten, jetzt sofort abzugleichen:

```bash
# reconcile = "jetzt sofort abgleichen, ohne auf die nächste Minute zu warten".
#   kustomization passes  welches Objekt abzugleichen ist
#   --with-source         zuerst für den frischen Commit zu Git gehen und erst dann anwenden;
#                         ohne dieses Flag arbeitet der Abgleich mit der zuvor heruntergeladenen Kopie
flux reconcile kustomization passes --with-source
```

Beachten Sie die Commit-Nachricht. `two replicas so the gate does not go dark during rollout` — das ist der Grund. In sechs Monaten, wenn jemand fragt „warum sind hier zwei und nicht eine“, ist die Antwort in fünf Sekunden gefunden:

```bash
# log = die Historie der Commits, das Frischeste oben.
#   --oneline         eine Zeile pro Commit: eine kurze Kennung und der Grundtext
#   apps/passes.yaml  nur die Commits zeigen, die genau diese Datei berührt haben
git log --oneline apps/passes.yaml
```

Weder das Dashboard noch `kubectl` hinterlässt eine solche Spur.

## Schritt 6. Prüfen wir, dass alles unter Kontrolle ist

📍 **Wo:** auf Ihrem Laptop.

Nacht, ein Vorfall, dem Dienst fehlen Kopien. Sie tun, was Sie immer getan haben:

```bash
# Die Anzahl der Kopien direkt im Cluster ändern, an Git vorbei — wie Sie es bis heute getan haben.
#   -n passes  die Anwendung lebt in diesem Namespace; ohne das Flag findet der Befehl sie nicht
kubectl scale deployment passes -n passes --replicas=5
```

```
deployment.apps/passes scaled
```

Es hat funktioniert. Prüfen wir:

```bash
# Die Spalte READY liest sich als "bereit/bestellt": wie viele Kopien antworten und wie viele es sein sollten.
kubectl get deployment passes -n passes
```

Fünf Kopien. Warten Sie eine Minute und schauen Sie erneut:

```bash
# Derselbe Befehl. Der einzige Unterschied ist, dass zwischen den beiden Ausführungen eine Minute verging.
kubectl get deployment passes -n passes
```

**Was Sie sehen werden:**

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
passes   2/2     2            2           8m
```

Wieder zwei Kopien. Ihr Befehl wurde ausgeführt und dann rückgängig gemacht.

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Wer hat es rückgängig gemacht? Warum geschah es stillschweigend, ohne einen einzigen Fehler als Antwort auf Ihren Befehl?
> Und am wichtigsten: Ist das ein Defekt, der behoben werden muss, oder arbeitet es wie beabsichtigt?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Flux hat es rückgängig gemacht, und genau dafür wurde es installiert.

Einmal pro Minute nimmt die `Kustomization`, was in Git steht, und vergleicht es mit dem, was im Cluster ist. Git sagt `replicas: 2`. Im Cluster fanden sich `5`. Eine Abweichung — was bedeutet, dass der Cluster falsch liegt, denn er ist nicht die Quelle der Wahrheit.

**Warum `kubectl scale` keinen Fehler zurückgab.** Es konnte gar nicht: Es tat ehrlich genau das, worum es gebeten wurde. Kubernetes nahm die Änderung an, die Kopien kamen tatsächlich hoch. Eine Minute später kam der Abgleich und stellte den beschriebenen Zustand wieder her. Niemand stritt mit niemandem — verschiedene Mechanismen arbeiteten jeder nach seinen eigenen Regeln.

**Warum das ein Feature ist und kein Bug.** Gehen Sie zurück zu dem Schmerz, mit dem das Lab begann: Sie sind zu dritt, jemand hat etwas von Hand geändert, und niemand weiß, was wo eingestellt ist. Jetzt passiert das nicht mehr. Eine Änderung außerhalb von Git lebt bis zum nächsten Abgleich — das heißt, sie lebt nicht. Daraus folgen drei Dinge:

1. **Der Cluster kann nicht stillschweigend fehlkonfiguriert werden.** Nicht „es ist verpönt“, sondern physisch unmöglich.
2. **Git beschreibt immer die Realität.** Nicht „sollte beschreiben“ — es beschreibt sie, weil die Abweichung sich selbst entfernt.
3. **Die Wiederherstellung des Clusters wird zu einer langweiligen Prozedur.** Flux installieren, ihm das Repository geben, warten. Alles, was da war, kommt zurück, weil alles aufgeschrieben ist.

**Die Lehre reicht über diesen Fehler hinaus.** Sie haben gerade den Unterschied zwischen „anwenden und vergessen“ und „ständig abgleichen“ gesehen. Ein gewöhnliches `kubectl apply` ist ein Schuss: Der Zustand änderte sich und lebt dann für sich, und jeder kann ihn anstoßen. Der Abgleich ist kein Schuss, sondern ein Zug: Die Beschreibung zieht die Realität ständig zu sich heran.

Derselbe Mechanismus behebt übrigens auch Fehler, die nicht Ihre sind. Wenn ein Node-Ausfall einen Pod löscht oder jemand versehentlich den `Service` wegwischt — das kommt ebenfalls zurück.

**Wann es im Weg steht.** Es steht während eines Vorfalls im Weg, wenn Sie wirklich sofort etwas ändern müssen und keine Zeit zum Diskutieren ist. Für solche Fälle kann Flux pausieren:

```bash
# suspend = den Abgleich für dieses Objekt pausieren. Flux hört auf, den Cluster in die
# Beschreibung zu bringen, und manuelle Änderungen beginnen zu leben. Der Inhalt von Git ändert sich unterdessen nicht.
flux suspend kustomization passes
```

Danach läuft der Abgleich nicht, und von Hand können Sie alles tun. Um es umzukehren:

```bash
# resume = den Abgleich wieder einschalten. Der nächste Abgleich entfernt alles, was von Hand getan wurde.
flux resume kustomization passes
```

⚠️ Pausieren ist eine aufgeschobene Schuld: Solange die `Kustomization` pausiert ist, hört Git wieder auf, die Realität zu beschreiben, und Sie sind genau dort, wo Sie angefangen haben. Es gibt eine Regel: pausiert — stellen Sie sich eine Erinnerung, es wieder einzuschalten.

</details>

## Schritt 7. Zurückrollen über `git revert`

📍 **Wo:** auf Ihrem Laptop.

Nun eine echte Situation. Sie rollen eine Änderung aus, und sie erweist sich als schlecht.

Nehmen Sie eine Änderung vor: Sagen wir, jemand drückt ohne nachzudenken den Speicher auf einen unbrauchbaren Wert herunter. Ändern Sie in `apps/passes.yaml` das Speicherlimit:

```yaml
          resources:
            requests:
              cpu: 20m
              memory: 4Mi
            limits:
              cpu: 300m
              memory: 4Mi
```

Schicken Sie es. Eine wissentlich schlechte Änderung reist denselben Weg wie eine gute: Im Moment gibt es keine Prüfung zwischen Ihrem `push` und dem Cluster — und das ist der Sinn dieses Schritts.

```bash
# Dieselben add, commit, push. Der Grund im Commit ist ehrlich geschrieben — er wird sich als nützlich erweisen,
# in fünf Minuten, wenn die Änderung rückgängig gemacht werden muss.
git add apps/passes.yaml
git commit -m "passes: trim memory limit"
git push
```

Wir warten und beobachten:

```bash
# Die Kopien beobachten, bis der Abgleich die neue Beschreibung bringt.
kubectl get pods -n passes -w
```

**Was Sie sehen sollten** — neue Kopien kommen nicht hoch. Der Zustand `OOMKilled` bedeutet, dass der Prozess wegen Überschreitung des Speicherlimits getötet wurde; `CrashLoopBackOff` bedeutet, dass der Cluster die Kopie bereits mehrmals hintereinander neu gestartet hat und nun immer länger bis zum nächsten Versuch wartet. Nginx passt nicht in vier Megabyte und stirbt gleich nach dem Start.

```bash
# Dieselbe Liste, aber als einzelne Momentaufnahme, ohne Beobachtung.
kubectl get pods -n passes
```

```
NAME                      READY   STATUS             RESTARTS   AGE
passes-6c9d4f7b8-2xk4n    1/1     Running            0          12m
passes-7f8a1b2c3-qq7lp    0/1     CrashLoopBackOff   3          90s
```

Die alte Kopie läuft noch — der Dienst lebt, aber das Update ist stecken geblieben. Zeit zum Zurückrollen.

**Wie Sie früher zurückgerollt hätten:**

```bash
# undo würde das Deployment auf die vorherige Revision zurücksetzen — auf die Einstellungen von vor der Änderung.
kubectl rollout undo deployment/passes -n passes
```

Dieser Befehl wird funktionieren. Die Kopien kehren zum vorherigen Image und zu den vorherigen Einstellungen zurück, und in zwanzig Sekunden ist alles gut — bis zu dem Moment, in dem Flux mit Git abgleicht. Und in Git steht immer noch `memory: 4Mi`. Innerhalb einer Minute kommt der kaputte Zustand zurück.

**Machen Sie kein `rollout undo`. Rollen Sie dort zurück, wo die Wahrheit lebt** — in Git:

```bash
# revert = einen neuen Commit hinzufügen, der die Änderungen des angegebenen rückgängig macht.
#   HEAD       "der letzte Commit des aktuellen Branch" — genau der mit dem schlechten Limit
#   --no-edit  keinen Editor für die Commit-Nachricht öffnen; Git schreibt die Kopfzeile selbst
git revert --no-edit HEAD
# Bis der rückgängig machende Commit zu GitHub geschickt wird, weiß Flux nichts davon.
git push
```

**Was Sie sehen sollten** — einen neuen Commit mit der Kopfzeile `Revert "passes: trim memory limit"`, und innerhalb einer Minute wieder zwei funktionierende Kopien im Cluster.

```bash
# Die Kopien kommen wieder hoch: das funktionierende Speicherlimit ist zurück.
kubectl get pods -n passes
# Und hier sehen Sie, welcher Commit jetzt angewendet ist — er sollte mit dem rückgängig machenden übereinstimmen.
flux get kustomizations
```

<details>
<summary><b>Wie sich <code>git revert</code> von „stell es wieder so her, wie es war“ unterscheidet</b></summary>

`git revert` löscht den schlechten Commit nicht. Es fügt einen **neuen** Commit hinzu, der die Änderungen des schlechten rückgängig macht. Alles bleibt in der Historie: was kaputt war, wann es bemerkt wurde und was zurückgerollt wurde.

```bash
# -4 — die vier neuesten Commits zeigen; der oberste ist der frischeste.
git log --oneline -4
```

```
9f3c1ab Revert "passes: trim memory limit"
5d2b8e0 passes: trim memory limit
c71a4f9 passes: two replicas so the gate does not go dark during rollout
0e5f2d3 add passes service v1
```

Vergleichen Sie das damit, wie es ohne Git aussieht. Einen Monat später hat die Frage „Moment, sind wir schon einmal in diese Falle getappt?“ keine Antwort: `kubectl rollout undo` hinterlässt keine Spur, und die Revisionshistorie des `Deployment` behält die letzten zehn und stirbt zusammen mit dem Objekt.

Hier haben Sie vier Zeilen, aus denen Sie sehen können: ja, das haben wir, hier ist wann, hier ist wer, hier ist, was genau getan wurde, hier ist, wie lange es vor dem Zurückrollen lebte.

**Es gibt auch einen zweiten Befehl — `git reset`, der die Historie tatsächlich löscht.** In einem gemeinsamen Repository wird er nicht verwendet: Ein Commit, den Sie auf Ihrer Maschine gelöscht haben, ist noch auf den Maschinen zweier Kollegen, und deren nächster `push` bringt ihn zurück. Rückgängigmachen in einem gemeinsamen Branch ist immer `revert`.

</details>

## Schritt 8. Review über einen Pull Request

📍 **Wo:** im Browser, auf GitHub.

Der letzte Teil des Schmerzes, den wir heilen: Eine Änderung reiste sofort zum Cluster, und niemand hat sie angesehen. Das schlechte Speicherlimit aus dem vorigen Schritt wäre in zehn Sekunden durch das Review gefallen — aber es gab kein Review.

Legen Sie einen Branch für die Änderung an:

```bash
# checkout -b = einen neuen Branch anlegen und sofort dorthin wechseln. Ein Branch ist eine eigene Linie
# von Änderungen: Commits, die darin gemacht werden, erreichen `main` nicht und damit auch nicht den Cluster.
#   passes/version-line  der Branch-Name; ein Schrägstrich im Namen ist erlaubt und dient der Gruppierung
git checkout -b passes/version-line
```

Ändern Sie in `apps/passes.yaml` die Zeile der Seite — zum Beispiel die Version im Text von `v1` auf `v1.1`. Schicken Sie den Branch:

```bash
git add apps/passes.yaml
git commit -m "passes: bump the version shown on the page"
# origin — der Name, unter dem Git die Adresse merkt, von der Sie das Repository geklont haben.
#   -u origin passes/version-line  einen gleichnamigen Branch in GitHub anlegen und die
#                                  Verbindung damit merken, sodass später ein bloßes `git push` genügt
git push -u origin passes/version-line
```

Als Antwort gibt GitHub einen Link zum Erstellen eines Pull Requests aus. Öffnen Sie ihn.

**Schauen Sie sich den Tab „Files changed“ an.** Das ist Infrastruktur-Review: nicht „Pete sagt, er habe die Limits gefixt“, sondern konkrete Zeilen — vorher und nachher, hervorgehoben. Ihr Kollege sieht genau, was zum Cluster reisen wird, und kann einen Kommentar zu einer bestimmten Zeile hinterlassen.

Der Cluster hat sich unterdessen nicht geändert und wird es nicht: `GitRepository` schaut auf den `main`-Branch, und die Änderung lebt in einem anderen Branch.

Klicken Sie auf **Merge pull request** — die Änderung landet in `main`, und der nächste Abgleich bringt sie zum Cluster. Nach einer Minute öffnen wir einen Tunnel und sehen uns an, was der Dienst ausliefert:

```bash
# port-forward = ein temporärer Tunnel von Ihrem Laptop in den Cluster.
#   -n passes     der Namespace, in dem der Dienst lebt
#   svc/passes    wohin wir führen: zum Service, nicht zu einer bestimmten Kopie
#   8080:80       links der Port auf Ihrem Laptop, rechts der Port des Dienstes im Cluster
kubectl port-forward -n passes svc/passes 8080:80
```

📍 **Im Browser** <http://localhost:8080> — die Seite zeigt `v1.1`. Schließen Sie den Tunnel mit `Ctrl+C`.

Der vollständige Weg einer Änderung ist nun dieser: **Branch → Pull Request → Review → Merge → Cluster**. An keinem Schritt hat jemand den Cluster von Hand betreten.

<details>
<summary><b>Was davon in der Produktion gemacht wird, was wir nicht gemacht haben</b></summary>

Drei Dinge, die ein produktives Repository obendrauf ergänzt:

**Branch Protection.** In den GitHub-Einstellungen ist der `main`-Branch für direkte Pushes gesperrt, und der einzige Weg hinein ist ein Pull Request mit einer Freigabe. Sonst beruht die Disziplin auf gutem Willen, und guter Wille bricht um drei Uhr morgens.

**Prüfungen vor dem Merge.** Automatisierung prüft die Manifeste auf Syntax und auf Richtlinienkonformität, bevor sie zum Cluster reisen, und lässt kaputte nicht mergen.

**Mehrere Umgebungen.** Üblicherweise enthält das Repository nicht einen Ordner, sondern `apps/staging` und `apps/production`, jeder mit seiner eigenen `Kustomization` in seinem eigenen Cluster. Eine Änderung reist zuerst nach Staging, setzt sich, dann nach Production.

Wir haben das nicht gemacht, weil jede Sache eine eigene Stunde ist, und die Mechanik ändert sich dadurch nicht: Die Quelle der Wahrheit ist weiterhin Git, und Flux zieht den Cluster weiterhin zu ihr hin.

</details>

## Überprüfung

📍 **Wo:** auf Ihrem Laptop, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

```bash
# Zurück zum Lab-Ordner: Das Skript lebt dort, und Sie haben im Ordner Ihres eigenen Repositorys gearbeitet.
cd labs/05-gitops
export KUBECONFIG=~/lab.kubeconfig
# Das Skript ändert nichts im Cluster: Es liest nur den Zustand und gibt einen Bericht aus.
./check.sh
```

⚠️ **Unter Windows läuft das Skript aus WSL**, nicht aus PowerShell — wie man es installiert, steht am Anfang von Lab 0. Ohne WSL können Sie das Lab dennoch abschließen, aber es wird kein Bericht-Artefakt geben.

Das Skript prüft nicht die Tatsache, dass Flux installiert ist, sondern dass der Mechanismus funktioniert: Die Flux-Dienste leben, die Quelle zeigt auf Ihr Repository und liest erfolgreich daraus, die Objekte im Cluster gehören wirklich zu Flux (statt von Hand angewendet worden zu sein), der Dienst antwortet über HTTP, und der Abgleich ist nicht pausiert.

Falls Sie möchten, dass das Skript auch in die Historie Ihres Repositorys schaut — zeigen Sie ihm, wo der Klon lebt:

```bash
# LAB_REPO — die Variable, aus der das Skript erfährt, wo der Klon Ihres Repositorys lebt.
# Tragen Sie Ihren eigenen Pfad ein, falls Sie es an einen anderen Ort als das Home-Verzeichnis geklont haben.
export LAB_REPO=~/passes-gitops
./check.sh
```

Dann prüft es zusätzlich, dass der im Cluster angewendete Commit mit dem neuesten in Ihrem Branch übereinstimmt und dass das Zurückrollen über `revert` gemacht wurde.

## Aufräumen

Wir löschen nichts: Das Repository und Flux werden später gebraucht — die nächsten Dienste gelangen auf dieselbe Weise in den Cluster.

Wenn Sie mit allen Labs fertig sind, können Sie alles auf einmal so entfernen:

```bash
# delete kustomization = das Abgleichsobjekt aus dem Cluster entfernen.
#   --silent  nicht erneut nach Bestätigung fragen
flux delete kustomization passes --silent
```

Wegen `prune: true` verschwindet alles, was die `Kustomization` gebracht hat, mit ihr: die Anwendung, die Einstellungen und der `passes`-Namespace selbst. Nichts muss von Hand aufgelistet werden, und niemand vergisst einen Rest — denn Flux führt die Liste dessen, was erstellt wurde, für sich selbst.

Das ist übrigens ein eigener Vorteil von GitOps, der nicht sofort auffällt. Einen Dienst vollständig zu löschen ist ein `git rm` des Ordners und ein `push`.

## Was wir jetzt können

- Den Zustand des Clusters in Git halten und verstehen, wie sich das von `kubectl apply` unterscheidet
- Flux in unseren Cluster installieren und es auf ein Repository richten
- Erklären, was ein Abgleich ist und warum eine Änderung außerhalb von Git nicht überlebt
- Über `git revert` zurückrollen statt über `kubectl rollout undo`
- Eine Infrastrukturänderung durch einen Pull Request und ein Review führen

## Und in vSphere wäre das

Die nächste Analogie ist ein Blueprint in vRealize Automation: Die gewünschte Konfiguration wird separat beschrieben und aus der Beschreibung ausgerollt. Aber von dort trennen sich die Wege. Ein Blueprint rollt aus und lässt los; wenn danach jemand in vCenter geht und den Speicher einer Maschine ändert, erfährt der Blueprint nichts davon. Compliance-Werkzeuge zeigen die Abweichung in einem Bericht — und das war's, ein Mensch geht hin, um sie aufzulösen.

Hier löst sich die Abweichung von selbst auf, jede Minute, ohne Bericht und ohne Menschen.

Der zweite Unterschied betrifft die Historie. In vCenter gibt es ein Task-Protokoll: wer was und wann getan hat. Es beantwortet die Frage „was passiert ist“, aber nicht „warum“ und „wie es sein sollte“. Git hat beides: den Text der Änderung, den Autor, den Grund in der Commit-Nachricht und die Diskussion im Pull Request.

**Wo vSphere ehrlich gesagt bequemer ist.** Drei Dinge.

**Die Einstiegshürde.** Um den Speicher einer virtuellen Maschine in vCenter zu ändern, müssen Sie vCenter bedienen können. Um ihn hier zu ändern, müssen Sie Git bedienen können: Branches, Commits, Merges, Konflikte. Für jemanden, der Git nicht kennt, ist das nicht „bequemer“ — es ist ein neuer Beruf, und in den ersten zwei Wochen arbeitet er langsamer als zuvor.

**Reaktionsgeschwindigkeit.** In einem Notfall wollen Sie den Zustand jetzt ändern, nicht über einen Branch, eine Review und eine Minute Abgleich. Der Pause-Mechanismus existiert, aber Sie müssen daran denken, ihn zu benutzen, und daran denken, ihn wieder auszuschalten.

**Klarheit im Fehlerfall.** Wenn in vCenter etwas nicht ausgerollt wird, wird Ihnen ein Task mit einem Fehler angezeigt. Wenn es hier nicht ausgerollt wird, müssen Sie den Zustand des `GitRepository` ansehen, dann die `Kustomization`, dann die Events, dann die Logs zweier Dienste. Die Diagnose ist über Schichten verteilt, und das ist ehrlich gesagt unbequem, bis man sich daran gewöhnt hat.
