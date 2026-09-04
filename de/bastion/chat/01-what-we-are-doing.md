## 1. Was wir hier eigentlich tun

**Lesen Sie dies vor Ihrem ersten Befehl. Danach ergibt alles Weitere mehr Sinn.**

### Was Sie gerade haben

Einen internen Dienst „Orders“. In vSphere sind ihm **drei virtuelle Maschinen** zugeteilt —
genau so, wie das üblicherweise aussieht:

| Maschine | Was darauf läuft | Adresse |
|---|---|---|
| `app` | die Anwendung `orders-api` in Java, CentOS 7 | — |
| `db` | PostgreSQL, von Hand installiert | `192.168.10.30` |
| `mq` | Kafka, von Hand installiert | `192.168.10.40` |

Die Anwendung ist in Spring Boot geschrieben, läuft als gewöhnlicher systemd-Dienst, und ihre
Einstellungen liegen in `/etc/orders/application.properties`. Und genau dort wird es interessant:

```properties
spring.datasource.url=jdbc:postgresql://192.168.10.30:5432/orders
spring.kafka.bootstrap-servers=192.168.10.40:9092
```

**Die Adressen sind fest verdrahtet.** Keine Namen — Zahlen. Irgendjemand hat einmal drei Maschinen
aufgesetzt, die IPs in die Konfiguration getippt, und seitdem halten diese drei Zahlen die ganze
Installation zusammen. Ändern Sie das Subnetz, und die Anwendung fällt um. Verschieben Sie die
Datenbank auf einen anderen Host, und Sie müssen die Datei von Hand öffnen und den Dienst neu starten.

Wenn Sie darin gerade Ihre eigene Infrastruktur wiedererkannt haben — ja, bei allen sieht es so aus.

### Was wir dagegen tun werden

Wir bewegen **nur `app`**. Die beiden anderen Maschinen gehen nirgendwohin — an ihre Stelle nehmen wir
fertiges Postgres und Kafka aus dem Cozystack-Katalog.

Der Unterschied ist grundlegend. Alle drei VMs könnten Sie auch ohne uns umziehen — und Sie hätten am
Ende denselben Zoo, nur auf neuer Hardware. Dasselbe Postgres, das Sie 2019 installiert haben, das
niemand aktualisiert und von dem niemand ein Backup macht, weil „es dafür doch mal ein Skript gab“.
Ein Managed Service kommt mit Replikation, Backups und Monitoring, und Sie denken überhaupt nicht mehr
daran.

**Und dabei dürfen keine Daten verloren gehen** — die Bestellungen all dieser Jahre müssen in die neue
Datenbank übertragen werden. Das ist ein eigener Schritt, und in einer echten Migration ist es der
nervenaufreibendste.

Dieser Unterschied — „den Zoo umgezogen“ gegenüber „die Anwendung umgezogen und den Zoo weggeworfen“ —
das ist der Inhalt dieses Workshops.

Der Weg besteht aus drei Phasen.

**Phase 1 — das Image herausholen.** Der Datenträger der virtuellen Maschine aus vSphere muss in ein
Format umgewandelt werden, das Cozystack versteht, und irgendwo abgelegt werden, von wo der Cluster ihn
abholen kann. Das sind die Schritte 1–3.

**Phase 2 — die Maschine am neuen Ort hochfahren.** Aus dem exportierten Image richten wir eine VM ein,
nun in Cozystack, und bringen sie wieder zur Vernunft: Sie wird kein Netzwerk haben, weil die Hardware
ringsum eine andere geworden ist. Das sind die Schritte 4 und 6.

**Phase 3 — den Zoo wegwerfen.** Wir richten Postgres und Kafka aus dem Katalog ein, **übertragen die
Daten aus der alten Datenbank** und konfigurieren die Anwendung von den festgenagelten IPs auf
ordentliche Namen um. Das sind die Schritte 5, 7, 8, 9.

> **Falls Sie noch nie mit Kubernetes gearbeitet haben — das ist in Ordnung, so ist es beabsichtigt.**
> Jeder Begriff wird unterwegs erklärt, und die nächste Nachricht ist ein kleines Glossar, in dem all
> das in die Sprache von vSphere übersetzt ist.
