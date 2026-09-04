## 1. Was wir hier eigentlich tun

**Lesen Sie dies vor Ihrem ersten Befehl. Danach ergibt alles mehr Sinn.**

### Was Sie im Moment haben

Ein interner Dienst „Bestellungen“. In vSphere sind ihm **drei virtuelle Maschinen** zugeteilt —
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

**Die Adressen sind fest verdrahtet.** Keine Namen — Zahlen. Irgendwann hat jemand drei Maschinen
aufgesetzt, die IPs in die Konfiguration eingetragen, und seither halten diese drei Zahlen die ganze
Installation zusammen. Ändert sich das Subnetz, fällt die Anwendung aus. Zieht die Datenbank auf einen
anderen Host um, müssen Sie die Datei von Hand öffnen und den Dienst neu starten.

Wenn Sie darin gerade Ihre eigene Infrastruktur wiedererkannt haben — ja, so ist es bei allen.

### Was wir dagegen tun werden

Wir migrieren **nur `app`**. Die beiden anderen Maschinen ziehen nirgendwohin um — an ihre Stelle
nehmen wir fertige Postgres und Kafka aus dem Cozystack-Katalog.

Der Unterschied ist grundlegend. Alle drei VMs könnten Sie auch ohne uns umziehen — und Sie hätten am
Ende denselben Zoo, nur auf neuer Hardware. Dasselbe Postgres, das Sie 2019 installiert haben, das
niemand aktualisiert und das niemand sichert, weil „dafür gab es doch ein Skript“. Ein verwalteter
Dienst kommt mit Replikation, Backups und Monitoring, und Sie denken überhaupt nicht mehr an ihn.

**Und dabei dürfen keine Daten verloren gehen** — die Bestellungen all dieser Jahre müssen in die neue
Datenbank übertragen werden. Das ist ein eigener Schritt, und in einer echten Migration ist er der
nervenaufreibendste.

Genau dieser Unterschied — „den Zoo umgezogen“ gegenüber „die Anwendung umgezogen und den Zoo
weggeworfen“ — ist der Inhalt dieses Workshops.

Der Weg besteht aus drei Phasen.

**Phase 1 — das Image herausholen.** Die Festplatte der virtuellen Maschine aus vSphere muss in ein
Format gebracht werden, das Cozystack versteht, und irgendwo abgelegt werden, von wo der Cluster es
abholen kann. Das sind die Schritte 1–3.

**Phase 2 — die Maschine am neuen Ort hochfahren.** Aus dem exportierten Image fahren wir eine VM hoch,
nun in Cozystack, und bringen sie wieder zu Sinnen: Sie wird kein Netzwerk haben, weil sich die Hardware
um sie herum verändert hat. Das sind die Schritte 4 und 6.

**Phase 3 — den Zoo wegwerfen.** Wir fahren Postgres und Kafka aus dem Katalog hoch, **übertragen die
Daten aus der alten Datenbank** und konfigurieren die Anwendung von den fest verdrahteten IPs auf
ordentliche Namen um. Das sind die Schritte 5, 7, 8, 9.

> **Wenn Sie noch nie mit Kubernetes gearbeitet haben — das ist in Ordnung, so ist es beabsichtigt.**
> Jeder Begriff wird unterwegs erklärt, und die nächste Nachricht ist ein kleines Glossar, in dem all
> das in die Sprache von vSphere übersetzt wird.
