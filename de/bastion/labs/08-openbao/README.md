# Lab 8 · Secrets raus aus dem Manifest

| | |
|---|---|
| **Zeit** | 50 Minuten, ein Teil davon Warten, während der Speicher hochfährt und Sie ihn entsiegeln |
| **Was es beweist** | Ein Passwort lässt sich endgültig aus Git entfernen und ändern, ohne eine einzige Datei anzufassen |
| **Was Sie brauchen** | Der Cluster aus Lab 0 und `~/lab.kubeconfig`; Zugang zum Dashboard Ihres Tenants; eine Tenant-Nummer der Form `workshopXX` |

> ⚠️ **`workshopXX` ist ein Platzhalter, kein Name.** Setzen Sie Ihre eigene Tenant-Nummer ein,
> sonst geht der Befehl in einen fremden Tenant und Sie bekommen einen Fehler „Zugriff verweigert“
> — oder schlimmer, fremde Daten. Ihre Nummer haben Sie zusammen mit Ihrem Passwort erhalten.

> ⚠️ **Ein dichtes Lab: elf Schritte und ein ungewohntes Zugriffsmodell.**
> Planen Sie es für einen eigenen Abend ein.

## Warum das wichtig ist

Der Passes-Dienst funktioniert: ein Mitarbeiter beantragt einen Passierschein für einen Gast, der Sicherheitsdienst sieht die Liste.
Das Sicherheitsteam erschien zu einem routinemäßigen Audit und brachte eine einzige Zeile aus Ihrem Repository mit:

```yaml
- name: DB_PASSWORD
  value: "Propusk2019!"
```

Das Passwort für die Passes-Datenbank sitzt in einem Manifest. Das Manifest sitzt in Git. Git ist für zwölf Leute
aus drei Teams sichtbar, vier weitere haben das Unternehmen verlassen, und eine vollständige Kopie des
Repositorys liegt auf der VM eines Auftragnehmers, der letztes Jahr eine Integration gemacht hat.

Die Frage des Auditors klingt alltäglich: **„ändern Sie dieses Passwort und zeigen Sie mir, wer es
im letzten Monat gelesen hat."** Es gibt nichts zu antworten. Das Passwort zu ändern heißt, jede Stelle zu
finden, an der es hartkodiert ist; wer es gelesen hat, ist unbekannt, weil das Lesen einer Datei aus Git
nirgends aufgezeichnet wird.

In diesem Lab lagern wir das Passwort in OpenBao aus, bringen der Anwendung bei, es von dort zu holen, ändern
das Passwort mit einem einzigen Befehl und sehen, was das System darüber weiß.

Unterwegs klären wir eine Frage, über die fast alle stolpern: **wie sich ein Secret in Kubernetes
von einem echten Secrets-Speicher unterscheidet.**

Jeder Begriff in diesem Lab wird beim ersten Auftreten ausgeschrieben, und der nächste Abschnitt ist ein
Glossar der bereits eingeführten.

## Glossar

| Begriff | Was es ist | Ähnlich wie… aber |
|---|---|---|
| **Secret (Kubernetes)** | Ein Cluster-Objekt, das Daten in base64 enthält | **Eine Passwortdatei auf der Festplatte einer VM**, sieht aber geschützt aus und ist es nicht — das nehmen wir unten auseinander |
| **base64** | Eine Möglichkeit, beliebige Bytes als druckbare Zeichen zu schreiben | **uuencode, ein MIME-Anhang**, aber es ist keine Verschlüsselung. Es gibt keinen Schlüssel, und jeder kann es rückgängig machen |
| **Secrets-Speicher** | Ein separater Dienst: hält Secrets verschlüsselt und gibt sie nach Regeln heraus | **Kein direktes Analogon**, aber es ist kein „Netzwerkordner voller Passwörter“ — es ist ein Dienst mit Policies, Ablaufzeiten und einem Log |
| **OpenBao** | Ein solcher Speicher. Ein Fork von HashiCorp Vault, veröffentlicht unter der MPL-Lizenz | die Befehle und die API entsprechen Vault; nur das Werkzeug heißt `bao` |
| **Root-Token** | Ein Konto mit vollem Zugriff auf alles | **root**, aber Sie verwenden es einmal bei der Einrichtung und geben danach eng gefasste Token aus |

Der Rest des Vokabulars dieses Labs — `sealed`, Unseal-Key, Policy, Token, KV v2, Rotation, Audit-Log,
Init-Container — wird unterwegs eingeführt, in dem Schritt, in dem er zuerst gebraucht wird. Sie müssen sich
das jetzt nicht merken: losgelöst von der Handlung bleibt es ohnehin nicht hängen.

<details>
<summary><b>Falls Sie die ganze Liste vorab möchten</b></summary>

| Begriff | Was es ist | Ähnlich wie… aber |
|---|---|---|
| **Versiegelt (sealed)** | Der Dienst läuft, aber der Master-Key ist nicht im Speicher: die Daten liegen verschlüsselt und die API weist Anfragen ab | **„Der Dienst ist hochgefahren, aber das Volume ist nicht gemountet“**, aber nach jedem Neustart müssen Sie ihn erneut entsiegeln, von Hand |
| **Unseal-Key** | Ein Anteil des Master-Keys, mit dem der Speicher entsiegelt wird | **Ein Schlüssel zu einem Safe**, aber es gibt mehrere Anteile, und standardmäßig müssen Sie mehr als einen vorlegen |
| **Policy** | Eine Liste von Pfaden und dem, was auf ihnen erlaubt ist | **Eine ACL auf einem Ordner**, aber der Pfad ist eine Adresse in der API, keine Datei auf der Festplatte |
| **Token** | Ein temporärer Passierschein zum Speicher | **Eine Sitzung**, aber ein Token hat eine Lebensdauer, läuft von selbst ab und kann widerrufen werden |
| **KV v2** | Eine „Key-Value“-Engine mit Versionshistorie | **Ein Ordner mit Dateien und Änderungshistorie**, aber sie behält jede Version und den Zeitstempel jeder Schreiboperation; der alte Wert verschwindet nie |
| **Rotation** | Ein planmäßiger Austausch eines Secrets durch ein neues | **Ein Passwort nach Zeitplan ändern**, aber hier ist es ein einziger Befehl, und die Anwendung übernimmt es beim nächsten Start |
| **Audit-Log** | Eine Aufzeichnung von „wer hat was und wann angefragt“ | **Ein Zugriffs-Log für eine Dateifreigabe**, aber für jede API-Anfrage wird eine Zeile geschrieben, auch für fehlgeschlagene und für Ablehnungen |
| **Secret Zero** | Das eine Secret, mit dem eine Anwendung ihr Recht auf alle anderen nachweist | es lässt sich nicht vollständig beseitigen. Es lässt sich kurzlebig, eng gefasst und einmalig machen |
| **Init-Container** | Ein Container, der läuft und sich beendet, bevor der Haupt-Container startet | **Ein Startskript, das läuft, bevor ein Dienst hochkommt**, aber wenn es fehlschlägt, startet der Haupt-Container gar nicht — und genau das wollen Sie |

</details>

## Was im Lab-Ordner liegt

Sie haben bereits alle Dateien — Sie haben sie mit dem Repository bekommen. Es gibt nichts zu erstellen oder
abzutippen: Überall, wo im Text unten `kubectl apply -f name.yaml` steht, stammt die Datei von hier.

```bash
cd labs/08-openbao
```

| Datei | Was es ist | Wann Sie es brauchen |
|---|---|---|
| `openbao.yaml` | Eine Bestellung für einen Secrets-Speicher — dasselbe wie der Button im Dashboard | Sie wenden es **im Tenant** an, nicht im Cluster `lab` |
| `secrets-demo-naive.yaml` | Wie der Dienst heute aussieht: das Passwort direkt in der Datei. Das hat das Audit gefunden | Sie wenden es auf Ihrem eigenen Cluster `lab` an |
| `secrets-demo-secret.yaml` | Die „naive Lösung“: das Passwort in ein Secret ausgelagert — und warum das nicht reicht | Sie wenden es an derselben Stelle an |
| `secrets-demo.yaml` | Die finale Version: das Passwort ist nirgends — nicht im Klartext, nicht in base64 | Sie wenden es an derselben Stelle an |
| `check.sh` | Eine Prüfung, dass die Anwendung ihr Passwort aus dem Speicher bezieht | Sie führen es am Ende des Labs aus |

## Schritt 1. Das Problem mit eigenen Augen sehen

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

Reproduzieren wir den Fund des Audits bei uns selbst: Wir bringen im Lab-Cluster einen kleinen Dienst
`secrets-demo` hoch, dem das Passwort direkt aus seiner Beschreibung übergeben wird. Zuerst gehen wir die
Datei durch, dann wenden wir sie an.

<details>
<summary><b>Genauer betrachtet: was in secrets-demo-naive.yaml steht</b></summary>

Dies ist ein gewöhnliches `Deployment` — eine Beschreibung einer Anwendung: welches Image zu nehmen ist und
wie viele Kopien laufen sollen. **Ein Image** ist ein fertiger Schnappschuss eines Dateisystems mit einem
Programm darin; das nächste Analogon in vSphere ist eine VM-Vorlage, nur ohne Betriebssystem.
**Ein Container** ist eine laufende Instanz eines Image. **Ein Pod** ist die kleinste Ausführungseinheit
in Kubernetes: ein oder mehrere Container, die immer zusammen leben und sterben.
Das Deployment sorgt dafür, dass die Anzahl der laufenden Pods der bestellten Anzahl entspricht.

```yaml
      containers:
        - name: app
          image: busybox:1.36
```

Die echte Passes-Anwendung, die Sie im Lab über Ihre eigene Registry in Go gebaut haben, fassen wir hier
nicht an: sie funktioniert, und es gibt keinen Grund, sie für eine Übung kaputtzumachen. Deshalb bringen wir
daneben einen separaten kleinen Dienst `secrets-demo` hoch — uns interessiert nicht die Anwendung, sondern der
Weg, auf dem das Passwort zu ihr gelangt. Darum steht an ihrer Stelle ein winziger Container, der die
einzige sinnvolle Sache tut — alle zehn Sekunden schreibt er ins Log, mit welchem Passwort er arbeitet.

```yaml
          env:
            - name: DB_PASSWORD
              value: "Propusk2019!"
```

Diese Zeile ist der ganze Punkt des Gesprächs. Umgebungsvariablen sind die gewöhnlichste Art, einer Anwendung
Konfiguration zu übergeben: `env` im Manifest wird zu einer Variablen im Container. Der Mechanismus ist gut;
schlecht ist der **Wert, der direkt in der Datei steht**.

```yaml
                  "$(printf %s "$DB_PASSWORD" | sha256sum | cut -c1-12)"
```

Die Anwendung gibt nicht das Passwort aus, sondern seinen **Fingerabdruck** — die ersten zwölf Zeichen des
sha256. Der Fingerabdruck zeigt, dass sich das Passwort geändert hat, doch das Passwort selbst lässt sich
daraus nicht rekonstruieren. So sollten Logs geschrieben werden; wir verwenden das bis zum Ende des Labs.

`resources.requests` ist, wie viel Ressourcen als Garantie zu reservieren sind (das Analogon zur reservation
in vSphere), `resources.limits` ist die Obergrenze, über die es nicht steigen darf (das Analogon zum
limit). Die Werte sind bewusst winzig: die Anwendung tut nichts.

</details>

**Wenden Sie es an.**

```bash
# KUBECONFIG sagt kubectl, mit welchem Cluster es sprechen soll. Hier ist es der Lab-Cluster
# aus Lab 0; der Tenant wird später gebraucht, im Schritt, in dem wir den Speicher bestellen.
export KUBECONFIG=~/lab.kubeconfig
cd labs/08-openbao
# apply = „bring den Cluster in den Zustand, der in der Datei beschrieben ist". -f = die Beschreibung aus der Datei nehmen.
# Ein Objekt mit diesem Namen existiert noch nicht, also wird es erstellt.
kubectl apply -f secrets-demo-naive.yaml
```

**Was Sie sehen sollten** — eine Zeile, die auf das Wort `created` endet.

Sehen wir uns an, was wir bekommen haben:

```bash
# logs = zeigen, was die Anwendung in ihre Ausgabe geschrieben hat. Es gibt keine separate Log-Datei.
#   deploy/secrets-demo  die Ausgabe des Pods nehmen, der nach dieser Beschreibung hochgefahren wurde
#   --tail=2             nur die letzten zwei Zeilen, nicht alles seit dem Start
kubectl logs deploy/secrets-demo --tail=2
```

**Was Sie sehen sollten** — etwa so:

```
08:14:31 connecting to passes-db.internal as passes_app, password fingerprint sha256:a609df223d57
```

Die Anwendung funktioniert. Das Passwort ist in einer Datei, die Datei ist in Git. Das ist genau die
Situation, die das Audit gefunden hat.

## Schritt 2. Die naive Lösung: das Passwort in ein Secret auslagern

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

Das Erste, was jede Internetsuche vorschlägt: „Kubernetes hat dafür ein Secret.“ Machen wir es wie
empfohlen — und sehen zuerst, was sich in der Datei ändert.

<details>
<summary><b>Was sich im Manifest geändert hat</b></summary>

Ein separates Objekt ist hinzugekommen:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: passes-db
type: Opaque
data:
  password: UHJvcHVzazIwMTkh
```

Ein `Secret` ist ein Cluster-Objekt für sensible Daten. Werte im Feld `data` werden in base64 geschrieben,
deshalb steht in der Datei anstelle von `Propusk2019!` nun `UHJvcHVzazIwMTkh`.

Und im Deployment ist anstelle des Werts eine Referenz erschienen:

```yaml
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: passes-db
                  key: password
```

`valueFrom` statt `value` bedeutet: „nimm den Wert nicht von hier, sondern aus jenem Objekt dort drüben.“
Kubernetes setzt beim Start des Containers den Inhalt des Schlüssels `password` aus dem Secret `passes-db` in
die Variable `DB_PASSWORD` ein.

Das ist an sich die richtige Technik — auf ein Secret zu verweisen, statt den Wert einzutragen.
Die Frage ist, was am anderen Ende der Referenz liegt.

</details>

**Wenden Sie es an.**

```bash
# Dasselbe apply. Die Datei enthält zwei Objekte — ein Secret und das geänderte Deployment; der Cluster
# vergleicht das Beschriebene mit dem, was er bereits hat, und gleicht beides an.
kubectl apply -f secrets-demo-secret.yaml
```

Vergewissern wir uns, dass die Anwendung weiterhin funktioniert:

```bash
# rollout status wartet, bis die neue Version der Anwendung die alte vollständig ersetzt hat, und gibt erst
# dann die Kontrolle zurück. Ohne es könnten Sie die Logs des alten Pods lesen.
kubectl rollout status deploy/secrets-demo
kubectl logs deploy/secrets-demo --tail=2
```

Der Fingerabdruck ist derselbe — `sha256:a609df223d57`. Die Anwendung hat dasselbe Passwort auf einem
anderen Weg bekommen.

**Problem gelöst?** Das Passwort steht nicht mehr im Deployment. In der Datei sitzt eine unverständliche
Zeichenkette. Prüfen wir das.

## Ein vorhersehbarer Fehlschlag · „Secret“ bedeutet nicht „verschlüsselt“

Versuchen Sie sich zu überzeugen, dass jetzt alles gut ist. Fragen Sie den Cluster, was im Secret steckt:

```bash
# get … -o yaml = „zeig das Objekt vollständig, genau so, wie der Cluster es speichert".
# Schauen Sie auf das Feld data — das ist der Inhalt des Secrets.
kubectl get secret passes-db -o yaml
```

Sie sehen dieselbe Zeichenkette `UHJvcHVzazIwMTkh`. Sie sieht unverständlich aus und damit sicher.

Jetzt ein Befehl:

```bash
#   -o jsonpath='{.data.password}'  genau ein Feld aus dem Objekt ziehen, ohne die Hülle
#   | base64 -d                     es weiterreichen und dekodieren: d = decode
#   ; echo                          einen abschließenden Zeilenumbruch ausgeben, sonst klebt das Ergebnis
#                                   an der nächsten Terminal-Eingabeaufforderung
kubectl get secret passes-db -o jsonpath='{.data.password}' | base64 -d; echo
```

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Was genau haben Sie gerade getan, um das Passwort zu bekommen? Welchen Schlüssel haben Sie gebraucht?
> Wer sonst kann diesen Befehl ausführen?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Die Ausgabe ist `Propusk2019!`. Im Klartext.

**base64 ist keine Verschlüsselung, sondern eine Kodierung.** Es wurde erfunden, um beliebige Bytes über
Kanäle zu tragen, die für Text gebaut sind: E-Mail-Anhänge, Daten in JSON, Binärdateien in
Konfigurationsdateien. Es steckt kein Schlüssel darin, weil auch kein Schutz darin steckt. Jeder kann es
rückgängig machen — jeder Mensch, jeder Browser, jede Decoder-Website.

Kubernetes verwendet base64 in einem Secret aus genau diesem Grund: Man kann keine beliebigen Bytes
(etwa ein Zertifikat oder einen Schlüssel) in YAML legen, aber in base64 schon. Das Wort „Secret“ im
Namen des Objekts bedeutet „hier kommt Sensibles hinein“, nicht „hier ist es geschützt“.

Was das in der Praxis bedeutet:

| Aussage | Wahr? |
|---|---|
| Ein Secret ist im Cluster verschlüsselt | Nein. Im Datenspeicher des Clusters liegt es nahezu im Klartext, sofern ein Administrator nicht separat Encryption at Rest aktiviert hat |
| Ein Secret kann man in Git committen | Nein. Das ist dasselbe, als würde man das Passwort dort ablegen |
| Man kann sehen, wer ein Secret gelesen hat | Nein. Ein gewöhnliches Lesen des Objekts wird nirgends aufgezeichnet |
| Ein Secret kann man ohne Berechtigungen nicht lesen | Wahr, und das ist der einzige echte Schutz. Berechtigungen im Cluster beschränken den Zugriff tatsächlich |
| Ein Secret ändert sich selbst nach Zeitplan | Nein. Sie ändern es, von Hand, an allen Stellen zugleich |

**Die Lehre reicht über diesen Fehler hinaus.** Und der Kernpunkt. Selbst wenn all das gelöst wäre,
bleibt die Frage des Auditors: **zeigen Sie mir, wer das Passwort im letzten Monat gelesen hat.** Kubernetes
hat darauf überhaupt keine Antwort — nicht weil es schlecht gebaut wäre, sondern weil es nicht seine Aufgabe
ist. Das Speichern von Secrets ist eine eigene Aufgabe, und dafür gibt es einen eigenen Dienst.

Übrigens erlaubt Ihnen Ihre Rolle im Cozystack-Tenant **nicht**, Secrets über `kubectl` zu lesen —
versuchen Sie es, und Sie werden abgewiesen. Aber der Lab-Cluster aus Lab 0 gehört ganz Ihnen, und dort
sind Sie der Administrator. Genau deshalb hat der Befehl oben funktioniert.

</details>

## Schritt 3. OpenBao bestellen

📍 **Wo:** Im Browser, im Cozystack-Dashboard, in Ihrem Tenant.

Tenant → **Anwendung erstellen** → `OpenBAO`.

| Feld | Wert | Warum |
|---|---|---|
| Name | `secrets` | kurz, und Sie müssen es später in Adressen eintippen |
| Replicas | **1** | eine Testumgebung zum Üben. Ab zwei aktiviert der Chart Raft-Replikation, und das ist schon ein anderer Speichermodus |
| Size | `2Gi` | Secrets belegen Kilobytes; der Platz ist für interne Daten |
| Storage class | `replicated` | die Daten werden in drei Kopien über verschiedene Nodes verteilt |
| Resources preset | `t1.small` | 1 CPU, 512 MB |
| UI | aktiviert | die Weboberfläche innerhalb des Clusters |
| External | deaktiviert | wir stellen es nicht nach außen bereit |

⚠️ **Der Wechsel zwischen einer Kopie und mehreren ist kein Häkchen.** Eine Kopie speichert die Daten in
einer Datei, mehrere speichern sie in Raft. Ein Moduswechsel erfordert eine Datenmigration, deshalb wird die
Entscheidung in Produktion vor der Installation getroffen, nicht danach.

### Dasselbe als Text — und ein Durchgang durch die Felder

Der Lab-Ordner enthält `openbao.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: OpenBAO
metadata:
  name: secrets
  namespace: tenant-workshopXX
spec:
  replicas: 1
  size: 2Gi
  storageClass: replicated
  resourcesPreset: t1.small
  ui: true
  external: false
```

`apiVersion: apps.cozystack.io/v1alpha1` ist der Cozystack-Katalog selbst, nur von der Seite gesehen, von
der er wie eine API aussieht. Wenn Sie den Button drücken, setzt das Dashboard genau dieses Objekt zusammen
und schickt es an den Cluster. Der Button ist eine Schicht über dem Text, keine Alternative dazu.

`kind: OpenBAO` ist die Position im Katalog. Achten Sie auf die Groß-/Kleinschreibung: `OpenBAO`, nicht
`OpenBao`. Der Cluster ist bei der Schreibweise pingelig.

`namespace: tenant-workshopXX` — **verwaltete Dienste leben in Ihrem Tenant auf dem Management-Cluster,
nicht im Lab-Cluster aus Lab 0.** Das sind zwei verschiedene Cluster, und es ist wichtig, das für den Rest
des Labs im Kopf zu behalten: die Anwendung ist im einen, der Speicher im anderen.

`replicas`, `size`, `storageClass`, `resourcesPreset` — dasselbe, was Sie mit der Maus ausgefüllt haben.

`ui: true` — die Weboberfläche hochbringen. `external: false` — dem Dienst keine externe Adresse geben;
von innerhalb des Clusters ist er ohnehin erreichbar.

Diese Datei wird **nicht auf den Lab-Cluster** angewendet, sondern auf den Tenant:

```bash
# --kubeconfig benennt die Zugangsdatei explizit und überschreibt die Variable KUBECONFIG.
# So geht die Bestellung an den Tenant auf dem Management-Cluster, nicht an den Lab-Cluster.
kubectl --kubeconfig ~/.kube/config apply -f openbao.yaml
```

Der Verwaltungszugang zum Tenant ist auf diesem Bastion bereits eingerichtet — die Datei `~/.kube/config`
(tokenbasiert, es öffnet sich kein Browser). Es gibt nichts zu holen oder zu speichern.

Im weiteren Text nutzen wir diese Datei kaum: Dienste werden mit der Maus bestellt, und die Arbeit mit
OpenBao selbst läuft über dessen eigene API.

Warten Sie, bis die Anwendung einen bereiten Zustand erreicht. Das dauert ein bis zwei Minuten.

## Schritt 4. Einen Arbeits-Pod einrichten und die Verbindung prüfen

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

Hier müssen wir innehalten und die Aufteilung verstehen.

**OpenBao lebt in Ihrem Tenant auf dem Management-Cluster.** Ihre Rolle im Tenant erlaubt Ihnen, Dienste zu
bestellen und zu löschen, aber nicht, dort eigene Pods laufen zu lassen oder sich per Port-Forwarding mit
Diensten zu verbinden. Das ist kein Defekt, sondern eine Grenze: der Tenant ist ein Ort für verwaltete
Dienste, keine Werkbank.

**Ihre Werkbank ist der Lab-Cluster aus Lab 0.** Dort sind Sie der Administrator. Von dort erreichen wir
OpenBao — über die interne Adresse, die jeder Dienst hat:

```
openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
```

Zerlegen wir den Namen in seine Teile:

| Teil | Was es bedeutet |
|---|---|
| `openbao-` | ein Präfix, das der Katalog dem Namen voranstellt. Sie haben die Anwendung `secrets` genannt; die Objekte bekamen Namen wie `openbao-secrets…` |
| `secrets` | der Name, den Sie im Dashboard vergeben haben |
| `tenant-workshopXX` | Ihr Tenant. Setzen Sie Ihre eigene Nummer ein |
| `svc.cozy.local` | die interne Namenszone des Management-Clusters |
| `8200` | der API-Port von OpenBao |

Bringen wir einen Arbeits-Pod hoch. In ihm steckt das Werkzeug `bao` — damit steuern wir den Speicher, und
Sie müssen es nicht auf dem Bastion installieren. Setzen Sie Ihre eigene Tenant-Nummer ein:

```bash
# run erstellt einen einzelnen Pod aus dem angegebenen Image — eine wegwerfbare kleine Maschine im Cluster.
#   --image          woher der Inhalt zu nehmen ist: das offizielle OpenBao-Image mit dem Werkzeug bao
#   --restart=Never  nicht erneut hochfahren, sobald der Befehl darin fertig ist
#   --env            Umgebungsvariable des Pods: jeder Befehl darin sieht sie
#   --command --     alles nach den zwei Bindestrichen ist der Befehl, den der Pod ausführt
# sleep 86400 = „einen Tag lang nichts tun": wir brauchen den Pod nur als Arbeitsplatz.
kubectl run bao-workbench \
  --image=openbao/openbao:2.5.1 \
  --restart=Never \
  --env=BAO_ADDR=http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200 \
  --command -- sleep 86400
# wait hält das Terminal, bis die Bedingung erfüllt ist.
#   --for=condition=Ready  der Pod ist gestartet und bereit, Befehle anzunehmen
#   --timeout=120s         nach zwei Minuten aufgeben und einen Fehler zurückgeben
kubectl wait --for=condition=Ready pod/bao-workbench --timeout=120s
```

`BAO_ADDR` ist die Variable, aus der das Werkzeug `bao` die Adresse des Speichers nimmt. Einmal beim
Erstellen des Pods gesetzt, erspart sie uns `-address=…` in jedem Befehl.

Der Pod ist eine wegwerfbare Werkbank, um die es nicht schade ist: am Ende des Labs löschen wir ihn mit
einem Befehl.

Prüfen wir, dass der Tenant vom Lab-Cluster aus sichtbar ist:

```bash
# exec = einen Befehl in einem bereits laufenden Pod ausführen; der Befehl selbst kommt nach --.
# bao status fragt den Speicher nach seinem Zustand: ob er versiegelt ist, ob er initialisiert ist.
# Hier dient es zugleich als Verbindungsprüfung: es kam überhaupt eine Antwort — also ist der Tenant sichtbar.
kubectl exec bao-workbench -- bao status
```

**Was Sie sehen sollten** — eine Statustabelle. Die Werte `Initialized false` und
`Sealed true` sind hier korrekt: der Speicher läuft, ist aber noch nicht eingerichtet und geschlossen:

```
Key                Value
---                -----
Seal Type          shamir
Initialized        false
Sealed             true
Total Shares       0
Threshold          0
Version            2.5.0
Storage Type       file
```

⚠️ **Der Befehl gibt einen Exit-Code ungleich null zurück — 2, und das ist kein Fehler.** Bei `bao status`
bedeutet der Exit-Code den Zustand des Speichers, nicht den Erfolg des Befehls: 0 — entsiegelt,
2 — versiegelt. Wenn Ihre Shell einen Code ungleich null hervorhebt oder Sie den Hinweis
`command terminated with exit code 2` sehen — erschrecken Sie nicht, alles läuft, wie es soll.

⚠️ **Wenn der Befehl mit `connection refused`, `no such host` oder `i/o timeout` fehlschlägt —**
hat es keinen Sinn weiterzumachen; zuerst die Verbindung. Häufige Ursachen, in abnehmender Wahrscheinlichkeit:
Sie haben `workshopXX` nicht durch Ihre eigene Nummer ersetzt; die Anwendung im Dashboard ist noch nicht
bereit; ein Tippfehler im Namen. Der Name wird nach der Regel `openbao-<Anwendungsname>` gebildet: Sie haben
die Anwendung `secrets` genannt, also enthält die Adresse `openbao-secrets`, nicht `secrets`.

## Ein vorhersehbarer Fehlschlag · Der Speicher verweigert den Dienst

Die Verbindung steht, also können wir das Passwort ablegen. Versuchen Sie es:

```bash
# bao kv put = einen Eintrag im Speicher ablegen.
#   secret/passes/db  der Pfad, unter dem er liegen wird
#   password=…        der Inhalt des Eintrags: ein Paar „Feldname = Wert"
kubectl exec bao-workbench -- bao kv put secret/passes/db password=Propusk2026
```

**Was Sie sehen** — statt einer Schreibbestätigung eine Ablehnung:

```
Error making API request.
Code: 503. Errors:
* Vault is sealed
```

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Der Dienst läuft, der Port antwortet, doch der Speicher verweigert die Arbeit. Warum könnte ein laufender
> Dienst bewusst keine Anfragen bedienen? Und warum ist das höchstwahrscheinlich richtig so?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Schauen Sie sich die Ausgabe von `bao status` aus dem vorherigen Schritt genauer an:

```
Sealed             true
Initialized        false
```

**Ein versiegelter Speicher ist der normale Zustand eines frisch installierten OpenBao.** Die Daten auf der
Festplatte sind mit dem Master-Key verschlüsselt, und der Master-Key ist nicht im Speicher des Prozesses.
Bis er dort abgelegt wird, kann der Dienst weder etwas lesen noch schreiben, und er verweigert ehrlich alles.

Im weiteren Verlauf des Labs bedeutet „entsiegeln“ genau eine Sache: dem Speicher Anteile des Master-Keys
vorzulegen, damit er den Schlüssel in seinen Speicher legt. Das Wort hat nichts damit zu tun, etwas auf
Papier auszudrucken.

Warum es so gebaut ist. Läge der Master-Key neben den verschlüsselten Daten, würde die Verschlüsselung nichts
bedeuten: wer die Festplatte stiehlt, bekäme beides. Deshalb lebt der Schlüssel **nur im Arbeitsspeicher**
und gelangt dorthin, wenn ihn ein Mensch oder ein externes System vorlegt.

Daraus folgt eine Konsequenz, die man gleich akzeptieren sollte: **nach jedem Neustart des Pods ist OpenBao
wieder versiegelt.** Ein Node wurde neu gestartet, eine Version aktualisiert, der Cluster hat den Pod
umgesiedelt — und der Speicher antwortet wieder nicht, bis er entsiegelt ist. In Produktion löst man das mit
Auto-Unseal über ein externes Modul (ein Cloud-KMS, ein Hardware-HSM), und das ist ein eigenes Projekt.
Im Lab entsiegeln wir von Hand und sehen den Mechanismus live.

**Die Lehre reicht über diesen Fehler hinaus.** **Ein verwalteter Dienst hat Ihnen Installation,
Upgrades, Replikation und Backups abgenommen, aber nicht die operativen Entscheidungen.** Cozystack hat Ihnen
den OpenBao-Prozess in zwei Minuten hochgebracht. Wo die Unseal-Keys aufbewahrt werden, wer entsiegeln darf,
was um drei Uhr morgens zu tun ist, wenn ein Node neu gestartet ist — das sind weiterhin Ihre Fragen, und es
ist gut, dass die Plattform sie nicht stillschweigend für Sie beantwortet hat.

</details>

## Schritt 5. Initialisieren und entsiegeln

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

**Was jetzt passiert:** OpenBao erzeugt einen Master-Key, zerteilt ihn in Anteile und übergibt sie uns
zusammen mit einem Root-Token. Ein zweites Mal geschieht das nie — die Schlüssel werden genau einmal gezeigt.

```bash
# operator init läuft einmal im Leben des Speichers: es erstellt den Master-Key und gibt
# seine Anteile zusammen mit einem Root-Token aus. Diese Werte zeigt niemand ein zweites Mal.
#   -key-shares=1     in wie viele Anteile der Master-Key zerteilt wird
#   -key-threshold=1  wie viele Anteile vorgelegt werden müssen, um ihn wieder zusammenzusetzen
kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1
```

**Was Sie sehen sollten:**

```
Unseal Key 1: 8kJq…=
Initial Root Token: s.7Yx…
```

⚠️ **Kopieren Sie beide Werte jetzt sofort in eine Datei auf dem Bastion** — etwa in
`~/openbao-lab.txt`, und nicht nur in die Zwischenablage. Niemand zeigt sie ein zweites Mal. Verlieren Sie den
Unseal-Key, verlieren Sie jedes Secret im Speicher — sie wiederherzustellen ist by design unmöglich.

Sie brauchen beide mehr als einmal, und zwar dann:

- **den Unseal-Key** — jedes Mal, wenn der Pod des Speichers neu startet. Beim Neustart ist er wieder
  versiegelt, und jeder Befehl antwortet fortan mit `Code: 503 ... * Vault is sealed`.
  Das Heilmittel ist erneutes Entsiegeln mit demselben Befehl, von derselben Stelle, an der Sie aufgehört haben;
- **den Root-Token** — am Ende des Labs, für das Prüfskript. Zwischen diesen beiden Momenten vergeht
  fast das ganze Lab, und bis dahin haben Sie das Terminal höchstwahrscheinlich geschlossen.

<details>
<summary><b>Was `-key-shares` und `-key-threshold` bedeuten, und warum Produktion anders ist</b></summary>

Der Master-Key wird nicht als Ganzes herausgegeben. Er wird in `key-shares` Anteile zerteilt, und um ihn
wieder zusammenzusetzen, müssen Sie `key-threshold` davon vorlegen. Das Schema heißt Shamir's Secret Sharing.

Der Sinn ist, dass **keine einzelne Person das Entsiegeln allein durchführen kann**. Die klassische
Produktionskonfiguration sind fünf Anteile mit einem Schwellenwert von drei: die Anteile werden an fünf Halter
in verschiedenen Abteilungen verteilt, und um den Speicher nach einem Neustart hochzubringen, müssen Sie
beliebige drei zusammentragen. Ein Administrator, der geht, trägt den Zugang nicht mit sich fort, und ein
unredlicher Administrator bekommt ihn nicht im Alleingang.

Wir setzen einen Anteil und einen Schwellenwert von eins, weil Sie im Lab allein sind und wir den Mechanismus
wollen, nicht die Prozedur. **In Produktion dürfen Sie das nicht tun**, und das ist keine Formalität: ein
einziger Anteil bedeutet einen einzigen Punkt, von dem aus alles abfließen kann.

</details>

Entsiegeln Sie ihn. Setzen Sie Ihren eigenen Unseal-Key ein:

```bash
# unseal übergibt dem Speicher einen Anteil des Master-Keys. Sobald die Anteile den Schwellenwert erreichen,
# landet der Schlüssel im Speicher des Prozesses und der Speicher beginnt, Anfragen zu bedienen.
kubectl exec bao-workbench -- bao operator unseal <Ihr-Unseal-Key>
# Wir wiederholen status, um den geänderten Zustand zu sehen.
kubectl exec bao-workbench -- bao status
```

**Was Sie sehen sollten** — `Sealed  false` und `Initialized  true`.

Jetzt melden wir uns mit dem Root-Token an. Er wird im Arbeits-Pod gemerkt, und die folgenden Befehle
fragen nicht mehr nach dem Token:

```bash
# login tauscht den eingegebenen Token gegen einen Eintrag in einer Datei im Pod — von da an nimmt das Werkzeug
# den Token von dort selbst, und Sie müssen ihn nicht in jeden Befehl eintippen.
# -it gibt dem Pod ein Terminal: ohne es hat das Werkzeug keinen Ort, um seine Eingabeaufforderung auszugeben, und keinen, um Eingaben anzunehmen.
kubectl exec -it bao-workbench -- bao login
```

Das Werkzeug fragt nach dem Token und **zeigt ihn bei der Eingabe nicht an** — das ist so gewollt. Fügen Sie
den Initial Root Token aus der Ausgabe von `init` ein.

⚠️ **Wenn sich `bao login` beschwert, dass es die Token-Datei nicht schreiben kann**, übergeben Sie den Token
in jedem Befehl als Umgebungsvariable:
`kubectl exec bao-workbench -- env BAO_TOKEN='Ihr-Token' bao status`.
Das funktioniert, aber der Token landet in Ihrer Befehlshistorie — im Lab hinnehmbar, in Produktion nicht.

## Schritt 6. Die Engine aktivieren und das Passwort ablegen

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

Ein frisches OpenBao ist leer: es gibt darin nicht einen einzigen Ort, an den man etwas legen könnte.
Secrets-Engines werden explizit aktiviert.

```bash
# secrets enable schaltet eine Engine ein — einen Teil des Speichers, der eine Art von Arbeit beherrscht.
#   -path=secret  an welchen Pfad man sie hängt: ab hier wird alles als secret/… geschrieben
#   kv-v2         welche Engine genau: „Key-Value" mit Versionshistorie
kubectl exec bao-workbench -- bao secrets enable -path=secret kv-v2
```

<details>
<summary><b>Was eine Secrets-Engine ist und warum es mehr als eine gibt</b></summary>

OpenBao ist kein einzelner Speicher, sondern ein Satz von Engines, deren jede ihre eigene Arbeit beherrscht
und auf ihren eigenen Pfad gemountet ist:

| Engine | Was sie tut |
|---|---|
| `kv-v2` | speichert, was Sie hineinlegen, mit Versionshistorie. Ein gewöhnliches „Key-Value“ |
| Datenbank-Engines | **erstellen selbst** einen temporären Benutzer in PostgreSQL oder MongoDB für zwei Stunden und löschen ihn selbst |
| PKI | stellt Zertifikate auf Anfrage aus, statt einer jährlichen Anfrage an die Sicherheitsabteilung |
| transit | verschlüsselt Daten auf Anfrage, ohne sie zu speichern: der Schlüssel verlässt den Speicher nie |

`-path=secret` — auf welchen Pfad sie gemountet wird. Ab hier läuft aller Zugriff auf diese Engine
über `secret/…`.

Wir nehmen `kv-v2` — der einfachste Fall: wir haben ein fertiges Passwort, das abgelegt werden muss.
Die Datenbank-Engines sind weit interessanter: sie schaffen das dauerhafte Passwort als Phänomen ab, indem
sie der Anwendung für jeden Lauf ein temporäres Konto ausstellen. Das ist die nächste Stufe, und in die muss
man hineinwachsen; es ist sinnvoll, hier zu beginnen.

</details>

Legen Sie das Passwort ab:

```bash
# kv put schreibt eine ganze neue Version: die aufgeführten Felder werden zu ihrem Inhalt.
# Es kann beliebig viele Felder geben; hier sind es zwei — das Passwort und der Datenbank-Benutzername.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026 username=passes_app
```

**Was Sie sehen sollten** — eine kleine Tabelle mit `version  1` und einer Erstellungszeit.

Prüfen wir, dass es sich zurücklesen lässt:

```bash
# kv get liest den Eintrag und gibt seine Felder als Tabelle aus. Wir lesen noch mit dem Root-Token — das heißt,
# wir prüfen, dass der Eintrag angekommen ist, nicht dass die Berechtigungen der Anwendung reichen.
kubectl exec bao-workbench -- bao kv get secret/passes/db
```

## Schritt 7. Der Anwendung Zugriff geben — auf genau eine Zeile

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

Sie dürfen der Anwendung nicht den Root-Token geben: mit ihm kann man alles, einschließlich fremde Secrets
lesen und den Speicher löschen. Die Anwendung braucht Lesezugriff auf nur einen Pfad.

Schreiben wir eine Policy:

```bash
# policy write speichert eine benannte Liste von Berechtigungen im Speicher.
#   passes-read  der Name der Policy; unter ihm wird sie später einem Token gewährt
#   -            den Policy-Text vom Standard-Input nehmen statt aus einer Datei
#   -i           bei kubectl exec: diesen Input in den Pod weiterleiten
# <<'HCL' … HCL ist eine Möglichkeit, mehrzeiligen Text direkt in den Befehl zu übergeben, ohne Datei.
kubectl exec -i bao-workbench -- bao policy write passes-read - <<'HCL'
path "secret/data/passes/db" {
  capabilities = ["read"]
}
path "secret/metadata/passes/db" {
  capabilities = ["read"]
}
HCL
```

<details>
<summary><b>Die Policy lesen</b></summary>

Eine Policy ist eine Liste von Pfaden und dem, was auf ihnen erlaubt ist. Alles, was nicht ausdrücklich
erlaubt ist, ist verboten; ein separates „deny“ muss man nicht schreiben.

```hcl
path "secret/data/passes/db" {
  capabilities = ["read"]
}
```

`secret/data/passes/db` ist ein Pfad **in der API**, nicht im Dateisystem. In der `kv-v2`-Engine ist er
so aufgebaut: `secret` — wo die Engine gemountet ist, `data` — das interne Präfix der Engine selbst,
`passes/db` — das, was Sie im Befehl `kv put` angegeben haben.

⚠️ **Dieses Präfix `data` ist die Ursache der Hälfte aller rätselhaften Ablehnungen.** Auf der Kommandozeile
schreiben Sie `secret/passes/db`, in der Policy aber `secret/data/passes/db`. Das Werkzeug `bao kv`
fügt `data` für Sie ein; die Policy tut es nicht.

`capabilities = ["read"]` — nur lesen. Nicht schreiben, nicht löschen, nicht benachbarte Pfade auflisten.

Der zweite Block, `secret/metadata/passes/db`, ist Zugriff auf Versionsinformationen: wann geschrieben wurde,
wie viele Versionen es gibt, welche die aktuelle ist. Ebenfalls nur lesen.

`bao policy write passes-read -` — der abschließende Bindestrich bedeutet „lies den Inhalt vom
Standard-Input". Deshalb läuft der Befehl mit `kubectl exec -i`: das Flag `-i`
leitet den Input in den Pod weiter.

</details>

Geben Sie einen Token mit dieser Policy aus:

```bash
# token create gibt einen neuen Token aus und bindet einen Satz von Berechtigungen daran.
#   -policy=passes-read  welche Berechtigungen: die oben geschriebene Policy
#   -ttl=24h             Lebensdauer; nach einem Tag hört der Token von selbst auf zu funktionieren
#   -field=token         nur den Token-Wert ausgeben, ohne die Tabelle drumherum —
#                        so lässt er sich leicht kopieren und weitergeben
kubectl exec bao-workbench -- \
  bao token create -policy=passes-read -ttl=24h -field=token
```

**Was Sie sehen sollten** — eine einzelne Zeile mit dem Token.

Kopieren Sie den Token — Sie brauchen ihn gleich.

Die Lebensdauer ist hier keine Formalität. Der Token ist in ein Log gerutscht, in einem Backup gelandet,
mit dem Bastion abgeflossen — übermorgen ist er nutzlos. Ein Passwort in einem Manifest hat diese
Eigenschaft nicht.

## Schritt 8. Den Token in den Cluster legen und das Passwort aus dem Manifest entfernen

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

Die Anwendung braucht etwas, um OpenBao zu beweisen, dass sie die ist, für die sie sich ausgibt. Der Token
ist dieses Etwas.

```bash
# create secret generic erstellt ein Secret-Objekt direkt im Cluster, ohne den Umweg über eine Datei auf der Festplatte.
#   passes-bao-token      der Name des Objekts; die Beschreibung der Anwendung verweist über ihn auf das Secret
#   --from-literal=name=…  den Wert als Zeichenkette von der Kommandozeile setzen
#                          (es gibt auch --from-file, wenn der Wert in einer Datei liegt)
kubectl create secret generic passes-bao-token \
  --from-literal=token='Token-aus-dem-vorherigen-Schritt-einfügen'
```

**Beachten Sie: ein Befehl, keine Datei.** Der Token wird direkt im Cluster erstellt und gelangt nie in
Git — es gibt keine Datei, in die er gelangen könnte.

<details>
<summary><b>Secret Zero: ein ehrliches Wort darüber, was wir nicht besiegt haben</b></summary>

Ein berechtigter Einwand: wir haben das Datenbankpasswort entfernt, aber einen Token in den Cluster gelegt.
Haben wir nicht nur ein Problem gegen ein anderes getauscht?

Haben wir nicht, und so unterscheidet sich der Token vom Passwort:

| | Passwort im Manifest | Token im Cluster |
|---|---|---|
| Liegt in Git | ja, für immer, in der gesamten Commit-Historie | nein, es wurde per Befehl erstellt |
| Lebensdauer | ewig | ein Tag, dann von selbst tot |
| Was es gewährt | vollen Zugriff auf die Passes-Datenbank | das Lesen einer Zeile im Speicher |
| Widerruf | das Passwort überall ändern, wo es steht | ein Befehl, sofort |
| Man kann sehen, wer es benutzt hat | nein | ja, im Audit-Log |

Aber das schließt das Problem nicht vollständig, und so zu tun, als täte es das, wäre unehrlich. **Es gibt
immer ein Secret, mit dem die Anwendung ihr Recht auf die übrigen nachweist.** Es hat sogar einen Namen —
Secret Zero. Es zu beseitigen ist unmöglich: mit irgendetwas muss man sich ausweisen.

Was erwachsene Systeme damit tun:

- **Kubernetes-Authentifizierung.** OpenBao überprüft den Service-Token des Pods gegen Kubernetes selbst
  und stellt im Austausch seinen eigenen aus. Dann wird „Secret Zero“ zur Identität des Pods, die der Cluster
  vergibt, statt einer Zeichenkette, die ein Mensch dort abgelegt hat
- **Einmal-Token (Response Wrapping).** Ein Operator stellt einen Token aus, der einmal verwendet werden kann.
  Bekommt die Anwendung eine Ablehnung „bereits verwendet“, wurde der Token abgefangen — und das ist
  sofort sichtbar

Beide Ansätze existieren und funktionieren, aber in diesem Lab würden sie uns weit vom Weg abbringen. Behalten
Sie im Kopf, dass es einen Weg gibt, und dass das Ziel nicht „null Secrets“ ist, sondern „ein kurzlebiges,
eng gefasstes, widerrufbares Secret statt eines Dutzends ewiger".

</details>

Jetzt wenden wir das saubere Manifest an. Setzen Sie zuerst Ihre eigene Tenant-Nummer ein:

```bash
# sed bearbeitet Text nach dem Muster s/was-ersetzen/womit/g; g = an jeder Stelle der Zeile,
# nicht nur an der ersten. -i bedeutet „die Datei selbst bearbeiten", statt das Ergebnis
# auf den Bildschirm auszugeben. Anstelle von workshop03 aus dem Beispiel setzen Sie Ihre eigene Nummer ein.

# macOS: die leeren Anführungszeichen nach -i sind zwingend — sonst nimmt sed das nächste Wort
# als Erweiterung für die Backup-Datei und ersetzt nichts
sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
# Linux
sed -i 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
```

<details>
<summary><b>Genauer betrachtet: was in secrets-demo.yaml steht</b></summary>

Beginnen wir mit der Hauptsache: **finden Sie das Passwort in dieser Datei.** Es ist nicht da — nicht im
Klartext, nicht in base64, nicht als Referenz auf ein Objekt, in dem es läge.

```yaml
      volumes:
        - name: secrets
          emptyDir:
            medium: Memory
            sizeLimit: 1Mi
```

`emptyDir` ist ein temporärer Ordner, der so lange lebt wie der Pod und mit ihm verschwindet.
`medium: Memory` bedeutet, dass es keine Datei auf der Festplatte ist, sondern ein Bereich im
Arbeitsspeicher. Das Passwort gelangt weder auf die Festplatte des Nodes noch in einen Volume-Snapshot noch
in ein Backup.

```yaml
      initContainers:
        - name: fetch-secret
          image: openbao/openbao:2.5.1
```

Ein Init-Container ist ein Container, der **vor** dem Haupt-Container läuft und erfolgreich abschließen muss.
Schlägt er fehl, startet der Haupt-Container gar nicht. Für das Holen eines Secrets ist das genau das
Verhalten, das Sie wollen: die Anwendung sollte nicht mit einem leeren Passwort starten und dann bei ihrer
ersten Anfrage an die Datenbank scheitern.

```yaml
              bao kv get -field=password secret/passes/db \
                | tr -d '\n' > /secrets/db_password
              chmod 0400 /secrets/db_password
```

Wir nehmen ein Feld und schreiben es in eine Datei. `tr -d '\n'` entfernt den Zeilenumbruch, falls einer
auftaucht: ein Passwort mit einem zusätzlichen Zeichen am Ende funktioniert für die Datenbank nicht, und so
etwas aufzuspüren ist unangenehm. `chmod 0400` — nur der Eigentümer kann es lesen.

```yaml
          env:
            - name: BAO_ADDR
              value: http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
            - name: BAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: passes-bao-token
                  key: token
```

Die Adresse des Speichers und der Token. Der Token kommt per Referenz auf das Objekt, das Sie per Befehl
erstellt haben. Die Datei enthält nur den Namen des Objekts, und ein Name ist kein Secret.

```yaml
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 1000
        fsGroup: 1000
```

Alles läuft als Non-Root. `fsGroup` wird gebraucht, damit beide Container — der, der die Datei schreibt, und
der, der sie liest — Zugriff auf den Ordner haben. Ohne es schreibt der Init-Container eine Datei, die der
Haupt-Container nicht öffnen kann, und Sie grübeln eine halbe Stunde, wo Sie sich vertan haben.

```yaml
          volumeMounts:
            - name: secrets
              mountPath: /secrets
              readOnly: true
```

Der Ordner wird dem Haupt-Container nur lesend gegeben. Die Anwendung kann das Passwort weder beschädigen
noch austauschen.

</details>

**Wenden Sie es an.** Das Deployment wechselt auf eine neue Version: der Init-Container geht zum Speicher,
legt das Passwort in den Speicher des Pods und erst danach startet die Anwendung selbst.

```bash
kubectl apply -f secrets-demo.yaml
# Wir warten, bis die neue Version die alte vollständig ersetzt hat. Kann der Init-Container das Passwort
# nicht holen, endet das Warten nicht — und das ist genau das Verhalten, das wir wollen.
kubectl rollout status deploy/secrets-demo
```

## Schritt 9. Prüfen, dass die Anwendung ihr Passwort aus dem Speicher bezogen hat

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

Sehen wir zuerst, was der Init-Container gesagt hat:

```bash
# -c wählt einen Container im Pod. Hier gibt es zwei, und ohne -c kann kubectl nicht erraten, welchen
# Sie meinen. fetch-secret ist der, der vor dem Start der Anwendung lief.
kubectl logs deploy/secrets-demo -c fetch-secret
```

**Was Sie sehen sollten:**

```
password fetched from OpenBao, not present in the manifest
```

Jetzt der Dienst selbst:

```bash
# Der Haupt-Container: er liest die Datei, die der Init-Container abgelegt hat.
kubectl logs deploy/secrets-demo -c app --tail=2
```

Der Fingerabdruck hat sich **geändert** — er war `sha256:a609df223d57`, jetzt ist er ein anderer. Die
Anwendung arbeitet mit einem neuen Passwort, das in keiner Datei des Repositorys steht.

Entfernen wir das naive Secret; es wird nicht mehr gebraucht und ist nur im Weg:

```bash
# delete entfernt das Objekt aus dem Cluster. Die Anwendung verweist nicht mehr darauf,
# deshalb bricht das Löschen nichts.
kubectl delete secret passes-db
```

## Schritt 10. Rotation: das Passwort ändern, ohne eine einzige Datei anzufassen

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

Zurück zur ersten Forderung des Auditors: „ändern Sie das Passwort.“ Früher hieß das, jede Stelle zu finden,
an der es steht, sie zu korrigieren, zu committen, auszurollen und zu hoffen, dass nichts vergessen wurde.

Jetzt:

```bash
# Dasselbe kv put. Die vorige Version des Eintrags wird nicht gelöscht — daneben erscheint eine zweite.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026-herbst username=passes_app
# rollout restart erstellt die Pods der Anwendung neu, ohne eine einzige Zeile in ihrer Beschreibung zu ändern.
# Dafür war das alles: das neue Passwort wird beim nächsten Start übernommen.
kubectl rollout restart deploy/secrets-demo
kubectl rollout status deploy/secrets-demo
# Der Fingerabdruck im Log zeigt, dass sich das Passwort geändert hat, ohne das Passwort selbst zu zeigen.
kubectl logs deploy/secrets-demo -c app --tail=2
```

**Was Sie sehen sollten** — der Fingerabdruck hat sich erneut geändert. Zwei Befehle, null geänderte
Dateien, null Commits.

⚠️ **Die Anwendung übernimmt den neuen Wert beim Neustart, nicht sofort.** Wir holen das Secret beim Start
mit einem Init-Container — ein einfacher, verlässlicher Ansatz, aber die Aktualisierung erfordert einen
Neustart. Muss ein Dienst ein Secret im laufenden Betrieb übernehmen, fügen Sie einen Sidecar-Container
hinzu, der den Wert per Timer neu einliest und die Datei aktualisiert. Das ist komplexer, und damit sollten
Sie nicht beginnen.

Sehen wir uns die Historie an:

```bash
# kv metadata get zeigt nicht die Werte, sondern Informationen über die Versionen des Eintrags: wie viele es gibt,
# wann jede erstellt wurde und welche jetzt die aktuelle ist.
kubectl exec bao-workbench -- bao kv metadata get secret/passes/db
```

**Was Sie sehen sollten** — beide Versionen mit ihren Erstellungszeiten. Der alte Wert ist nicht
verschwunden: sollte sich zeigen, dass das neue Passwort der Datenbank nicht passt, gibt es einen Punkt, zu
dem man zurückkehren kann.

Sie können den vorigen Wert auch vollständig lesen:

```bash
# -version=1 liest die zuerst geschriebene Version statt der aktuellen.
kubectl exec bao-workbench -- bao kv get -version=1 secret/passes/db
```

Das ist **Rotation**: das Ersetzen eines Secrets durch ein neues nach Plan, nicht erst nachdem ein Leck
passiert ist. Eine Regel wie „Passwörter von Service-Accounts werden einmal im Quartal geändert“ wird vom
Unerreichbaren zu einer Zeile im Zeitplan.

## Schritt 11. Das Audit-Log: wer was angefragt hat

📍 **Wo:** Auf dem Bastion, im Lab-Cluster.

Die zweite Forderung des Auditors — „zeigen Sie mir, wer das Passwort gelesen hat.“ Schalten wir das Log ein:

```bash
# audit enable schaltet ein Audit-Device ein.
#   file              der Device-Typ: Einträge als Text schreiben
#   file_path=stdout  statt in eine Datei auf der Festplatte — in die Standardausgabe des Pods, von wo
#                     die Plattform die Logs einsammelt
kubectl exec bao-workbench -- bao audit enable file file_path=stdout
# audit list listet die aktivierten Devices auf — eine Prüfung, dass der Befehl oben durchging.
kubectl exec bao-workbench -- bao audit list
```

**Was Sie sehen sollten** — eine Tabelle mit einem aktivierten Device vom Typ `file`.

<details>
<summary><b>Was ins Audit-Log kommt und wie es sich von einem gewöhnlichen Log unterscheidet</b></summary>

Von diesem Moment an schreibt OpenBao einen Eintrag **für jede API-Anfrage**: wer gefragt hat (welcher
Token, welche Policy), was genau, wann, von welcher Adresse und was geantwortet wurde. Es gibt zwei Einträge
pro Anfrage — die Anfrage selbst und die Antwort darauf.

Drei Unterschiede zu einem vertrauten Anwendungs-Log:

**Auch Ablehnungen werden geschrieben.** Ein Versuch, einen fremden Pfad zu lesen, hinterlässt genau so eine
Spur wie ein erfolgreiches Lesen. Gerade die Ablehnungen interessieren das Sicherheitsteam: erfolgreiche
Lesevorgänge sind Arbeit, während eine Reihe von Ablehnungen Aufklärung ist.

**Secret-Werte gelangen nicht ins Log.** Pfade, Namen und Token werden gehasht; die Secrets selbst werden
nicht geschrieben. Das Log kann man nach außen geben, ohne dessen Inhalt gleich mit herauszugeben.

**Wenn es keinen Ort gibt, an den das Log geschrieben werden kann, hört OpenBao auf zu arbeiten.** Das ist
eine bewusste Entscheidung: ein Speicher, der Anfragen bedient, ohne sie aufzeichnen zu können, ist
schlechter als einer, der ausgefallen ist. Daraus folgt praktisch — richten Sie Ihr einziges Audit-Device
nicht auf eine Datei auf einer Festplatte, die volllaufen kann.

⚠️ **Dieses Log dürfen Sie im Lab nicht lesen, und das muss klar gesagt werden.** Wir haben es in die
Standardausgabe des OpenBao-Pods geleitet, und Ihre Rolle kann die Logs von Pods im Tenant nicht lesen —
der Tenant übergibt Ihnen die Verwaltung der Dienste, aber nicht den Zugriff auf ihr Inneres. In einer
echten Installation nimmt der Log-Collector der Plattform das Log auf und legt es dorthin, wo das
Sicherheitsteam es ansieht, nicht Sie über `kubectl`.

Was Sie selbst dennoch sehen können, ist die Versionshistorie aus dem vorherigen Schritt
(`bao kv metadata get`): wer und wann **geschrieben** hat, auf die Sekunde genau. Das ist kein
vollständiges Audit, aber es beantwortet die Frage „wann wurde das Passwort zuletzt geändert“.

</details>

## Die Prüfung

📍 **Wo:** Auf dem Bastion, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

```bash
cd labs/08-openbao
# Das Skript liest diese drei Umgebungsvariablen, deshalb müssen Sie sie vor dem Ausführen setzen
# und im selben Terminalfenster.
export KUBECONFIG=~/lab.kubeconfig     # welchen Cluster prüfen
export COZY_TENANT=workshop03          # Ihre Tenant-Nummer
export BAO_TOKEN='Ihr-Root-Token'      # der, den bao operator init ausgegeben hat
./check.sh
```

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell — wie man es einrichtet, steht
am Anfang von Lab 0. Sie können das Lab ohne WSL abschließen, aber es wird kein Report-Artefakt geben.

Das Skript prüft nicht die Tatsache, dass Manifeste angewendet wurden, sondern die Arbeit dem Wesen nach:
der Speicher ist entsiegelt, das Secret liest sich mit dem Token zurück, es gibt mehr als eine Version (also
hat eine Rotation stattgefunden), das Auditing ist an, und im Manifest der Anwendung steht kein einziges
Passwort im Klartext.

Daneben erscheint eine Report-Datei. **Kein einziges Secret gelangt in den Report** — nur Versionen,
Namen und Fingerabdrücke.

## Aufräumen

```bash
# delete -f = „aus dem Cluster alles entfernen, was in dieser Datei beschrieben ist".
kubectl delete -f secrets-demo.yaml
# Was per Befehl statt per Datei erstellt wurde, wird über den Namen gelöscht.
kubectl delete secret passes-bao-token
kubectl delete pod bao-workbench
```

OpenBao selbst wird im Dashboard gelöscht: die Anwendung `secrets` → löschen.

Warum das billig ist. Ein Secrets-Speicher in einer klassischen Installation ist ein Projekt: ein Server,
Clustering, Zertifikate, ein Entsiegelungsverfahren, Monitoring-Integration. Hier haben Sie ihn in zwei
Minuten bekommen und in zehn Sekunden zurückgegeben, und der von ihm belegte Platz ist freigegeben.

⚠️ **Mit dem Löschen verschwindet jedes Secret darin.** Der Unseal-Key und der Root-Token eines gelöschten
Speichers werden zu nutzlosen Zeichenketten. Haben Sie etwas Echtes dort abgelegt — holen Sie es zuerst
heraus.

## Was wir jetzt können

- Einem Kollegen erklären, warum ein Secret in Kubernetes nicht „verschlüsselt“ ist, und es mit einem
  einzigen Befehl belegen
- OpenBao bestellen, initialisieren und entsiegeln, im Verständnis dessen, was geschieht
- Ein Secret in den Speicher legen und der Anwendung mit einem kurzlebigen Token Zugriff auf genau einen
  Pfad gewähren
- Ein Passwort ändern, ohne eine einzige Datei im Repository anzufassen, und die Versionshistorie sehen
- Die Frage „wer hat dieses Passwort gelesen“ klar beantworten — und verstehen, woher die Antwort kommt

## Und in vSphere wäre das

Es gibt kein direktes Analogon, und das ist die ehrliche Antwort. In klassischer Infrastruktur leben
Passwörter von Service-Accounts an drei Orten zugleich: in einer Konfigurationsdatei auf einer VM, im
Passwortmanager der Abteilung und im Kopf dessen, der es eingerichtet hat. Rotation bedeutet einen Gang durch
alle drei, weshalb sie nicht gemacht wird. Die Frage „wer hat es gelesen“ hat keine Antwort, weil niemand
das Lesen einer Datei aufzeichnet.

Es gibt den vSphere Credential Store, es gibt den Windows Credential Manager, es gibt unternehmensweite
Passwortmanager — sie alle lösen das Problem „für einen Menschen ist es bequem, Passwörter aufzubewahren“.
Das Problem „eine Anwendung holt sich das Passwort selbst, nach Policy, auf Zeit und unter Aufzeichnung“
lösen sie nicht.

**Wo vSphere bequemer ist, ehrlich.** In nichts vom Obigen — aber Bequemlichkeit hat ihren Preis, und der
ist folgender.

Ein Passwort in einer Datei auf einer VM ist **immer verfügbar**: der Host wurde neu gestartet, die Maschine
kam hoch, der Dienst las die Datei und begann zu arbeiten. Niemand muss um drei Uhr morgens geweckt werden.
OpenBao ist nach einem Neustart versiegelt, und bis es entsiegelt ist, starten die Anwendungen nicht. Das
fügt Ihrer Infrastruktur einen neuen Ausfallpunkt und ein neues Verfahren hinzu — mit Bereitschaftspersonal,
mit Schlüsselhaltern, mit einem dokumentierten Prozess. Auto-Unseal über ein externes KMS beseitigt dieses
Problem, fügt aber eine Abhängigkeit von eben jenem externen KMS hinzu.

Und zweitens. Eine Datei auf der Festplatte versteht jeder Administrator auf den ersten Blick. Pfade,
Policies, Token, TTLs, das Präfix `data` mitten in einem Pfad — das ist ein eigenes Modell, das das Team
lernen muss, und die ersten paar Monate wird es eine Quelle rätselhafter Ablehnungen sein.

Der Gewinn überwiegt trotzdem, aber er ist nicht kostenlos, und Sie sollten die Migration mit diesen Kosten
im Kopf planen.
