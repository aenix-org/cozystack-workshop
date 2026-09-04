# Wie man Labs schreibt

Lesen Sie dies, bevor Sie zum ersten Mal ein Lab bearbeiten. Dieses Dokument hat ein einziges
Ziel: dafür zu sorgen, dass sich die fünfzehn Labs wie eine zusammenhängende Arbeit lesen und
nicht wie fünfzehn verschiedene.

## Wer der Leser ist

Eine VMware-Systemadministratorin oder ein VMware-Systemadministrator. Diese Person sieht
Kubernetes zum ersten Mal, oder fast zum ersten Mal, und **das ist in Ordnung** — das Material
richtet sich genau an diese Person. Sie ist klug, hat zwanzig Jahre Erfahrung und kennt
Virtualisierung, Netzwerke und Storage in- und auswendig. Was sie nicht kennt, ist unsere
Terminologie.

Alles Weitere folgt daraus.

## Sprachregeln

**Kein Begriff ohne Erklärung, wenn er zum ersten Mal in diesem Lab auftaucht.** Nicht „das
wurde in einem anderen Lab erklärt“ — die Labs werden in beliebiger Reihenfolge bearbeitet.
Erklären Sie ihn über etwas, das der Leser bereits aus vSphere kennt.

**Verbotene Wörter:** „einfach“, „offensichtlich“, „wie gewohnt“, „bloß“, „trivialerweise“.
Wenn etwas wirklich offensichtlich ist, braucht man es nicht zu schreiben. Wenn es nicht
offensichtlich ist, setzt „einfach“ den Leser herab.

**Sprechen Sie den Leser direkt mit „Sie“ an.** Keine verschämten Andeutungen, keine falsche
Kumpelhaftigkeit, keine Ausrufezeichen.

**Verkaufen Sie nicht.** Kein „leistungsstark“, „flexibel“, „löst jedes Problem out of the
box“. Der Nutzen zeigt sich über eine Tatsache und einen Vergleich, nicht über ein Adjektiv.
Statt „Cozystack bietet Hochverfügbarkeit“ — „löschen Sie einen Pod und schauen Sie auf die
Uhr“.

**Seien Sie ehrlich, was die Schwächen angeht.** Wenn etwas schlechter funktioniert als in
vSphere, sagen Sie es. Der Leser merkt es ohnehin, und wenn wir schwiegen, würde er dem Rest
nicht mehr vertrauen.

## Der vorgeschriebene Aufbau eines Labs

Eine Datei `README.md` im Ordner des Labs. Die Reihenfolge der Abschnitte ist verbindlich.

1. **Titel** — `# Lab NN · Name`
2. **Kopf** — die Zeit, was es beweist, was Sie brauchen
3. **Warum das** — eine Aufgabe aus dem echten Leben, nicht „jetzt lernen wir X“. Eine
   Fortsetzung des durchlaufenden Szenarios (siehe unten)
4. **Mini-Glossar** — nur die Begriffe, die in diesem Lab neu sind, als dreispaltige Tabelle:
   Begriff, was es ist, „wie … aber“. Die dritte Spalte nennt das Ding aus vSphere und sagt im
   selben Atemzug, wie sich der Begriff davon unterscheidet — in einer einzigen Wendung, nicht
   als zwei Fragmente in getrennten Zellen. Es darf keine eigene Spalte „wo die Analogie
   bricht“ geben: aus dem Zusammenhang gerissen bedeutet ihre Überschrift nichts
5. **Was im Ordner des Labs liegt** — eine Tabelle jeder Datei im Lab: Datei, was es ist, wann
   sie nützlich wird. Der Leser sollte nicht raten müssen, woher die `name.yaml` in einem
   `apply`-Befehl kommt oder ob er sie selbst anlegen muss. Jede Datei, die das Lab anwendet,
   muss in seinem Ordner liegen (oder in einem benachbarten, und dann wird der Pfad
   ausdrücklich ausgeschrieben: `../03-scale/hpa.yaml`)
6. **Schritte** — eine Aktion pro Schritt
7. **Überprüfung** — wie das Ergebnis aussehen soll und wie man es sieht
8. **Aufräumen** — verpflichtend, und mit einer Erklärung, warum es billig ist
9. **Was wir jetzt können** — drei oder vier Punkte
10. **Und in vSphere wäre das** — ein ehrlicher Vergleich, auch dort, wo vSphere bequemer ist

## Das durchlaufende Szenario

Alle Labs sind Teile einer einzigen Arbeitsaufgabe, nicht eine Sammlung von Übungen.

**Der Ausgangspunkt:** Sie sind im Plattform-Team. Das Business bittet Sie, einen internen
Dienst namens „Passes“ auszurollen — eine Mitarbeiterin bestellt über eine mobile App einen
Passierschein für einen Gast, der Sicherheitsdienst sieht die Liste am Kontrollpunkt, und das
Management schaut einmal im Monat in einen Bericht.

Jeder Dienst taucht **wegen eines konkreten Schmerzes** auf, nicht weil er an der Reihe ist:

| Was auftaucht | Weswegen |
|---|---|
| Harbor | der Sicherheitsdienst hat verboten, Images aus dem Internet zu ziehen |
| Redis | das Mitarbeiterverzeichnis im Altsystem braucht 800 ms für eine Antwort |
| MongoDB | Passierscheine haben unterschiedliche Felder: einmalig, wöchentlich, für ein Auto |
| OpenBao | ein Audit hat das Datenbank-Passwort in einem Manifest gefunden |
| ClickHouse | das Management will „wie viele Gäste, und wann die Spitzen liegen“ |
| Bucket | das Mobile-Team hat keinen Ort für die APK |
| GitOps | wir sind zu dritt, jemand hat etwas von Hand geändert und alles fiel aus |
| Catalog | Tochtergesellschaften wollen denselben Dienst für sich |

Die Labs 0–4 sind Übung an einer harmlosen Anwendung, bevor die eigentliche Aufgabe beginnt.
Das wird offen gesagt: „erst die Stützräder“.

## Code und Manifeste durchgehen

**Nirgends taucht YAML ohne eine Durchsprache auf.** Keine einzige Datei, die der Leser
anwendet, ohne sie verstanden zu haben.

Die Durchsprache kommt in einen Spoiler, damit der Hauptfluss nicht aufbläht:

```markdown
<details>
<summary><b>Das Manifest Zeile für Zeile durchgehen</b></summary>

... Zeile für Zeile, in Prosa ...

</details>
```

In der Durchsprache erklären wir, **warum der Block gebraucht wird**, nicht was in ihm steht.
Schlecht: „`replicas: 1` ist die Anzahl der Replicas.“ Gut: „`replicas: 1` — wie viele Kopien
am Laufen gehalten werden. Verschwindet eine Kopie, erstellt der Cluster ungefragt eine neue.
Daher kommt die Selbstheilung im nächsten Lab.“

## Vorhersehbare Fehlschläge

**Jedes Lab muss dort, wo es passt, eine Überprüfung enthalten, die nicht durchläuft.** Der
Leser fährt gegen die Wand, diagnostiziert sie und begreift von selbst, warum der nächste
Schritt nötig ist.

Die Form ist immer dieselbe, und ihre Reihenfolge wird nie umgestellt:

1. Wir schlagen eine Überprüfung vor, als wäre schon alles vorhanden
2. **Wir zeigen den Fehler** — zuerst die Ausgabe, dann die Fragen. Nicht umgekehrt
3. Wir halten den Leser an
4. Ein Spoiler mit der Antwort — und mit einer Lehre, die über diesen konkreten Fehler
   hinausgeht

Drei Stellen, an denen der Wortlaut wörtlich festgelegt ist, damit die Labs nicht
auseinanderdriften.

Der Stopp ist immer ein Blockzitat-Callout, ohne ⚠️ (dieser Marker ist Fallstricken
vorbehalten):

```markdown
> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Eine Frage. Eine zweite Frage, falls es eine gibt.
```

Die Überschrift des Spoilers lautet immer `Die Antwort und eine Lehre, die über diesen Fehler
hinausgeht`.

Der Absatz mit der Lehre selbst, im Spoiler, beginnt so: `**Die Lehre reicht über diesen
Fehler hinaus.**`

Der Fehlschlag muss echt sein, nicht inszeniert. Wenn ein Schritt funktioniert, muss man ihn
nicht künstlich kaputtmachen.

## Zwei Wege: mit der Maus und über Text

Wo eine Aktion sowohl im Dashboard als auch über `kubectl` verfügbar ist, zeigen wir **beide**
und sagen, wann welcher angebracht ist.

**Keiner der beiden Wege wird in einem Spoiler versteckt.** Die Arbeit über Text ist kein
Notbehelf für den Fall, dass das Dashboard ausfällt: Sie ist genau das, wohin wir den Leser
führen, denn eine Beschreibung in einer Datei lässt sich prüfen, in Git ablegen und
zurückrollen. Der Spoiler ist für das Durchgehen der Felder da, nicht für die Arbeitsweise
selbst.

Managed Services (Harbor, Redis, MongoDB, ClickHouse, OpenBao, Buckets, virtuelle Maschinen) —
steuern wir über das Dashboard: dort kommt das Gefühl von Self-Service durch.

Die eigene Anwendung — über `kubectl` und Git: dort kommt durch, dass Infrastruktur Text ist,
der sich prüfen und zurückrollen lässt.

## Konsistente Benennung

Eine Sache heißt in jedem Lab und in jeder Chat-Nachricht gleich. Der Leser geht das Material
in beliebiger Reihenfolge durch und sollte nicht raten müssen, dass `lab` und „der lab-Cluster“
ein und dasselbe sind.

| Ding | Wie wir es nennen |
|---|---|
| Die Einheit des Materials | „lab“. Nicht „Lab-Übung“, nicht „Modul“, nicht „Lektion“ |
| Der lab-Cluster aus Lab 0 | die Anwendung `lab` |
| Die Übungsanwendung der Labs 0–4 | `rickroll` |
| Der Produktionsdienst der Labs 5–14 | „Passes“ im Text, `passes` in den Manifesten |
| Die Tenant-Nummer | `workshopXX` in Platzhaltern, `workshop03` in ausgearbeiteten Beispielen |

Gesondert: **die Pfade zu den Zugangsdateien und die Namen der Umgebungsvariablen sind überall
gleich.** Wenn in einem Lab die Tenant-kubeconfig unter einem Pfad liegt und in einem
benachbarten unter einem anderen, wird der Leser schließen, dass es zwei verschiedene Dateien
sind, und am Ende zwei davon behalten.

Der Name eines Labs in seinem Titel und sein Kurzname in der Tabelle der Wurzel-`README.md`
müssen einander erkennbar sein. „Cache“ in der Tabelle und „Ein Cache vor einem langsamen
Backend“ in der Datei sind offensichtlich dasselbe Lab. Wenn die Tabelle ein Wort nennt und der
Titel ein anderes, öffnet der Leser Dateien aufs Geratewohl.

Die Zeit im Kopf des Labs und die Zeit in der Tabelle der Wurzel-`README.md` sind dieselbe
Zahl. Im Kopf geben wir die volle Zeit an, einschließlich Warten, und vermerken gesondert, wie
viel davon auf Warten entfällt.

## Formatierung

- Abschnitte und Schritte sind beide auf `##`-Ebene. Die Überschrift eines Schritts:
  `## Schritt N. Was wir tun`. Wir verwenden nicht die Wörter „Teil“, „Etappe“, „Übung“ —
  überall heißt es „Schritt“. Unterüberschriften innerhalb eines Schritts sind `###`, aber
  häufiger passt ein Spoiler besser
- Befehle stehen in Blöcken mit markierter Sprache: ` ```bash `, ` ```yaml `, ` ```sql `
- Vor jedem Befehl, was gleich passiert. Danach, was Sie sehen sollten
- Zeilen nicht länger als 100 Zeichen
- Emojis sind ausschließlich funktionale Marker: 📍 wo es läuft, ⚠️ ein Fallstrick. Mehr nicht
  in den Labs. In Chat-Nachrichten kommen hinzu 🖱 der Maus-Weg, 📄 eine Datei aus dem
  Repository, ⏳ ein langes Warten — und damit ist die Liste abgeschlossen
- Tabellen statt Listen, wo immer es Spalten gibt

## Überprüfung

In jedem Ordner liegt eine `check.sh`. Der Teilnehmer führt sie selbst aus und erhält einen
Bericht: was geprüft wurde, was bestanden hat, was nicht, samt beigefügtem Beleg. Die
Anforderungen an die Skripte stehen in `check/README.md`.

Im Text des Labs verweisen wir im Abschnitt „Überprüfung“ darauf.

## Was man nicht tun soll

- Verweisen Sie nicht auf Schrittnummern aus anderen Labs — sie werden in beliebiger
  Reihenfolge bearbeitet
- Verweisen Sie auch innerhalb Ihres eigenen Labs nicht auf eine Schrittnummer („der
  vorhersehbare Fehlschlag in Schritt 7“): Schritte verschieben sich beim Bearbeiten, und der
  Verweis wird unbemerkt irreführend. Schreiben Sie „etwas weiter im Lab“
- Setzen Sie nicht voraus, dass das vorherige Lab gemacht wurde, sofern es nicht unter „was Sie
  brauchen“ steht
- Lassen Sie keine `TODO`, `TBD` oder Platzhalter im veröffentlichten Text
- Erfinden Sie keine Manifest-Felder oder Secret-Namen. Prüfen Sie sie gegen
  `packages/apps/<app>/values.schema.json` im cozystack-Repository
