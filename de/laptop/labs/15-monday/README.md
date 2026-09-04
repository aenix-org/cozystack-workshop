# Lab 15 · Was am Montag zu tun ist

| | |
|---|---|
| **Zeit** | 20 Minuten, und kein einziger Befehl |
| **Was es zeigt** | Was Sie gelernt haben, lässt sich auf Ihren eigenen Bestand anwenden, wenn Sie klein anfangen |
| **Was Sie brauchen** | Nur Sie und eine Liste Ihrer Systeme |

Hier gibt es weder Befehle noch `check.sh`: Dieses Lab kann nur der Montag prüfen.
Ein Gespräch darüber, was als Nächstes zu tun ist, wenn die Testumgebung abgeschaltet ist und bei der Arbeit alles wieder wie zuvor ist.

## Was dabei herausgekommen ist

In vierzehn Labs haben Sie einen funktionierenden internen Dienst aufgebaut — „Pass“, über den ein
Mitarbeiter einen Passierschein für einen Gast anfordert, der Sicherheitsdienst am Eingang die Liste sieht und die Geschäftsführung einmal
im Monat einen Bericht ansieht. Jeder Teil entstand nicht der Reihe nach, sondern aus einem konkreten Schmerz:

| Was entstand | Weswegen |
|---|---|
| Eine eigene Image-Registry | Die Sicherheitsabteilung untersagte es, Images aus dem Internet zu ziehen |
| Ein Cache | das Mitarbeiterverzeichnis aus dem Legacy-System antwortete in 800 ms |
| Ein Dokumentenspeicher | Passierscheine haben unterschiedliche Felder: einmalig, für eine Woche, für ein Fahrzeug, als Gruppe |
| Ein Secret-Speicher | ein Audit fand das Datenbankpasswort in einem Manifest |
| Eine Analysedatenbank | die Geschäftsführung wollte wissen, wie viele Gäste es gibt und wann die Spitzen liegen |
| Ein Bucket | das Mobile-Team hatte keinen Ort für die gebauten APKs |
| Infrastruktur in Git | Sie sind zu dritt, jemand änderte etwas von Hand — und alles fiel aus |
| Ein eigener Eintrag im Katalog | Tochtergesellschaften wollten denselben Dienst für sich |

Keinen einzigen dieser Dienste haben Sie installiert oder aktualisiert: Es sind Katalogeinträge, für die die
Plattform verantwortlich ist. Installiert und repariert haben Sie nur Ihre eigene Anwendung.

Als Nächstes — wie sich das außerhalb der Testumgebung wiederholen lässt.

## Warum das wichtig ist

Das häufigste Schicksal einer solchen Schulung ist „interessant, aber bei uns klappt das nicht“. Nicht, weil
es nicht klappen würde, sondern weil nach vierzehn Labs unklar ist, wo man in der eigenen
Infrastruktur anfangen soll, in der dreihundert VMs stehen und niemand sich erinnert, was die Hälfte davon tut.

Gehen wir es der Reihe nach durch: womit anfangen, was nicht anfassen und wie man den Sinn denjenigen erklärt, die
das Budget freigeben.

## Womit anfangen: drei Kandidaten für den ersten Umzug

Nicht mit der wichtigsten Anwendung. Und nicht mit der am meisten vernachlässigten. Man beginnt mit
derjenigen, bei der ein Fehler billig und das Ergebnis sichtbar ist.

### Kandidat eins: das, was Sie ohnehin neu aufsetzen wollten

Jeder hat ein System, bei dem längst entschieden wurde „das sollten wir wirklich auf ein neues OS umziehen“ oder
„es ist Zeit, die Version zu aktualisieren“. Das ist der ideale erste Umzug: Sie wollten es ohnehin anfassen,
also ist das Risiko bereits im Plan eingeplant, und Sie brauchen genau gleich viele Freigaben.

### Kandidat zwei: eine Test- oder Demo-Umgebung

Eine Kopie der Produktivanwendung, um die es nicht schade ist. Hier prüfen Sie Ihre eigene Fähigkeit, die
Migration zu wiederholen, nicht die Plattform — die Plattform haben Sie bereits im Workshop geprüft. Der Unterschied ist,
dass es jetzt Ihre Images, Ihre Netzwerke und Ihre Sicherheitsrichtlinien sind.

### Kandidat drei: das, was nach neuen Ressourcen verlangt

Ein Team, das für einen neuen Dienst ein paar VMs braucht, ist der bequemste Fall. Nichts wird
migriert, alles wird von Grund auf neu erstellt, und Sie zeigen ihnen sofort ein Dashboard statt eines
Antragsformulars. Den Unterschied in der Geschwindigkeit sehen beide Seiten.

## Was man nicht als Erstes anfassen sollte

**Ein System mit einer an Hardware gebundenen Lizenz.** Prüfen Sie die Bedingungen, bevor Sie etwas
umziehen. Es gibt Produkte, die Lizenzen nach den physischen Kernen des Hypervisors zählen, und
der Umzug kann am Ende mehr kosten, als er einspart.

**Alles, was Sie nicht verstehen.** Wenn ein Dienstleister die Anwendung vor sieben Jahren installiert hat und
seither niemand darin war, wird die Migration zur Ermittlung. Das ist machbare Arbeit, aber nicht
die erste.

**Cluster-Systeme mit eigener Ausfallsicherheit.** Datenbanken mit Replikation, Anwendungscluster,
alles, was selbst auf seine eigenen Kopien achtet. Hier müssen Sie entscheiden, wer jetzt
für die Ausfallsicherheit verantwortlich ist — die Anwendung oder die Plattform — und das ist ein eigenes Gespräch mit dem
Eigentümer des Systems.

## Eine Reihenfolge, die funktioniert

1. **Eine Testumgebung aufsetzen.** Nicht für eine Migration — sondern damit Sie irgendwo jede Vermutung noch in
   derselben Stunde prüfen können, ohne einen Antrag zu stellen. Ein Server, eine Installation, null Verpflichtungen.
2. **Ein System aus den oben genannten umziehen.** Vollständig, mit seinen Daten, bis zum Zustand „es läuft und Benutzer
   sehen darauf“.
3. **Einen Monat damit leben.** Hier lernen Sie, was Ihnen kein Workshop geben kann: wie es sich
   um drei Uhr nachts verhält, was bei einem Update kaputtgeht, was im Monitoring fehlt.
4. **Erst jetzt einen Plan für den Rest aufstellen.** Mit Zahlen, die Sie auf Ihrer eigenen Hardware gewonnen haben, nicht
   aus einer Präsentation.

Zwischen Schritt 2 und 3 möchte man üblicherweise beschleunigen. Tun Sie es nicht: Ein Monat Betrieb eines einzelnen Systems
in der Produktion lehrt mehr als zehn Systeme, die in derselben Woche umgezogen wurden.

## Wie man das der Geschäftsführung erklärt

Das Gespräch wird nicht um Technik gehen. Drei Dinge entscheiden es üblicherweise.

**Lizenzkosten** — das häufigste, aber auch das rutschigste Argument. Rechnen Sie ehrlich:
Zur Ersparnis gehört nicht nur die Zeile, die Sie streichen, sondern auch die Kosten Ihrer Zeit für den Umzug,
und die Schulung des Teams und der Zeitraum, in dem beide Plattformen gleichzeitig laufen.

**Geschwindigkeit der Ressourcenbereitstellung.** Hier haben Sie eigene Erfahrung: Mit eigenen Händen haben Sie einen Cluster
in zehn Minuten und eine Datenbank in fünf hochgezogen. Vergleichen Sie das damit, wie lange derselbe Antrag bei Ihnen dauert.
Das ist eine Zahl, die das Business ohne Übersetzung versteht.

**Unabhängigkeit von einem einzelnen Anbieter.** Ein Argument, das in den letzten Jahren an Gewicht gewonnen hat.
Es wirkt nicht für sich allein, sondern im Zusammenspiel mit dem ersten: Die Fähigkeit, die Plattform zu wechseln, ist genau
das, was Ihnen eine Verhandlungsposition beim Preis verschafft.

Was man besser nicht verspricht: dass es einfacher wird. Wird es nicht — zumindest nicht im ersten Jahr.
Es wird günstiger, schneller bei der Ressourcenbereitstellung und frei von der Bindung an einen einzelnen Anbieter, aber
einfacher wird es nicht. Einfachheit zu versprechen ist der schnellste Weg, ein halbes Jahr später das Vertrauen zu verlieren.

## Wohin mit Fragen

- **Die Community auf Telegram** — derselbe Chat, in dem der Workshop lief. Die Frage „wie mache ich das
  richtig“ ist immer willkommen.
- **Dokumentation** — [cozystack.io/docs](https://cozystack.io/docs/).
- **Quellcode** — [github.com/cozystack/cozystack](https://github.com/cozystack/cozystack).
  Wenn sich etwas anders verhält als beschrieben, ist es meist schneller, in den Chart zu schauen, als
  zu raten. Das haben Sie schon im Lab über die eigene Registry gemacht.

## Was wir jetzt können

- Das erste umzuziehende System nach dem Kriterium „billig, sich zu irren“ wählen, nicht „am wichtigsten“
- Die Fälle, die man aufschieben sollte, von denen unterscheiden, die man jetzt angehen sollte
- Der Geschäftsführung keine Einfachheit versprechen, die es nicht geben wird
- Wissen, wo man fragt, wenn niemand in der Nähe die Antwort kennt

## Und in vSphere wäre das

Das Gespräch wäre kürzer: Sie wissen bereits, was am Montag zu tun ist, weil Sie es seit zehn Jahren tun. Das ist
die Differenz — nicht in der Technik, sondern darin, dass Sie hier Ihre Gewohnheiten von Grund auf neu
aufbauen müssen.

Die gute Nachricht ist, dass Sie sie schrittweise aufbauen können, ein System nach dem anderen. Die schlechte —
dass Sie die ersten Monate langsamer arbeiten werden als gewohnt. Die Geschwindigkeit kehrt zurück, je
mehr neue Gewohnheiten sich ansammeln — aber Sie müssen diesen Rückstand vorab in Ihre Zeitpläne
einplanen.
