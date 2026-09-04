# Check-Skripte

In jedem Lab-Ordner liegt eine `check.sh`. Sie prüft, ob das Lab wirklich abgeschlossen ist —
nicht dass „eine Datei angewendet wurde“, sondern dass es **inhaltlich funktioniert**.

Sie führen es selbst aus, wann immer Sie möchten. Das Ergebnis ist ein Bericht im Terminal und
eine Artefakt-Datei, die Sie überallhin anhängen können: in den Community-Chat, in einen
Zertifizierungsantrag, in Ihre eigenen Notizen.

## So führen Sie es aus

```bash
cd labs/03-scale
./check.sh
```

Sie sind auf dem Bastion (Linux) — `bash`, `kubectl` und alles Weitere, was Sie brauchen, ist
bereits vorhanden; nichts zu installieren. Die Zugangsdaten zum lab-Cluster — genau jene
`lab.kubeconfig`, die Sie in Lab 0 erstellt haben — findet das Skript über die Variable
`KUBECONFIG`:

```bash
export KUBECONFIG=~/lab.kubeconfig
```

> Wenn Sie die Labs nicht auf dem Bastion, sondern von Ihrem eigenen Windows-Rechner aus
> durchführen — wie Sie WSL installieren und wo Sie `lab.kubeconfig` bekommen, ist im
> Laptop-Kit beschrieben: [`../../laptop/check/README.md`](../../laptop/check/README.md).

Das Skript findet selbst heraus, wo es suchen muss — über die Variable `KUBECONFIG`. Ist sie
nicht gesetzt, sagt es Ihnen das und stoppt.

Für Labs, die Zugriff auf einen Tenant im Management-Cluster brauchen, benötigen Sie
zusätzlich die Variable `COZY_TENANT` — den Namen Ihres Tenants, zum Beispiel `workshop07`:

```bash
export COZY_TENANT=workshop07
./check.sh
```

## Was dabei herauskommt

Im Terminal — eine Zeile pro Prüfung:

```
[  OK  ] application deployed and responding
[  OK  ] Pod name is injected into the page
[ FAIL ] autoscaling is not configured
         no HorizontalPodAutoscaler found for deployment/rickroll
         hint: apply hpa.yaml from this folder
```

⚠️ **Der Bericht wird in den Lab-Ordner geschrieben und trägt Datum und Uhrzeit.** Wenn das
Repository gemeinsam genutzt wird oder Sie die Prüfung mehrmals ausgeführt haben, sammeln sich
dort mehrere Dateien an — achten Sie auf die Uhrzeit im Namen, damit Sie keinen fremden oder
früheren Durchlauf für Ihren eigenen halten.

Daneben erscheint eine Datei `report-<lab>-<date>.md` — dasselbe Ergebnis in Markdown, zusammen
mit den gesammelten Nachweisen: Versionen, Befehlsausgaben, Objektnamen. Das ist das Artefakt.

## Anforderungen an den Autor des Skripts

**Prüfen Sie die Substanz, nicht die Tatsache der Anwendung.** Schlecht: „Ein Deployment-Objekt
existiert." Gut: „Die Anwendung antwortet über HTTP, und die Antwort enthält den Namen des Pods.“

**Jeder Fehlschlag erklärt, was zu tun ist.** Eine `FAIL`-Zeile ohne Hinweis ist Ausschuss. Der
Leser führt das Skript gerade deshalb aus, weil er feststeckt.

**Das Skript repariert nichts und erstellt nichts.** Es liest nur. Die einzige Ausnahme ist ein
temporärer Pod zum Prüfen der Netzwerkerreichbarkeit, der sich selbst wieder aufräumt.

**Läuft auf macOS und Linux.** Kein GNU-spezifisches `sed -i`, `readlink -f`, `date -d`. Auf
beiden Systemen testen.

**Bricht nicht beim ersten Fehler ab.** Es führt jede Prüfung aus und zeigt das vollständige
Bild. `set -e` nicht verwenden.

**Gibt keine Passwörter oder Tokens aus.** Ist ein Wert geheim, schreiben Sie `<hidden>`.

**Idempotent.** Zehnmal hintereinander ausgeführt, ändert es den Zustand des Clusters nicht.

## Gemeinsame Bibliothek

`check/lib.sh` — gemeinsame Funktionen, wird am Anfang jedes Skripts eingebunden:

- `ok "Text"` / `fail "Text" "Hinweis"` / `warn "Text"` — ein Ergebnis ausgeben
- `need_kubeconfig` — prüfen, dass `KUBECONFIG` gesetzt ist und der Cluster antwortet
- `need_tenant` — prüfen, dass `COZY_TENANT` gesetzt ist
- `evidence "Überschrift" "Wert"` — einen Nachweis zum Artefakt hinzufügen
- `finish` — Fazit ziehen, den Bericht schreiben, den Exit-Code zurückgeben

Exit-Code: `0` — alles bestanden, `1` — es gibt Fehlschläge. So lässt sich das Skript in der
Automatisierung einsetzen.
