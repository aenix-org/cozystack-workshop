## 23. Genauer betrachtet: Was in 04-managed.yaml steckt

```yaml
kind: Postgres
metadata:
  name: db
spec:
  replicas: 1
  size: 10Gi
  storageClass: local
  resourcesPreset: t1.micro
  users:
    orders:
      password: Orders2019!
  databases:
    orders:
      roles:
        admin: [ orders ]
```

`kind: Postgres` — wieder die Katalog-Haltung, genau wie `Bucket` in der ersten Phase. Sie installieren keine Datenbank-Engine: Sie bestellen eine. Die Plattform selbst startet die Prozesse, richtet die Replikation ein, legt einen Backup-Zeitplan an und bindet das Monitoring an.

`users` und `databases` — die Plattform legt den Benutzer `orders` und die Datenbank `orders` an und erteilt diesem Benutzer Administratorrechte für diese Datenbank. Von Hand ist nichts zu erstellen: genau deshalb enthält die Schemadatei, die wir später anwenden, keine `CREATE DATABASE`- oder `CREATE USER`-Befehle — sie wurden bereits für Sie ausgeführt.

`replicas: 1` — eine einzige Kopie, eine Testumgebung zum Üben. In einem Produktivsystem setzen Sie mehr, und dann verfolgt die Plattform selbst, welche die primäre ist, und schaltet bei einem Ausfall um.

`resourcesPreset: t1.micro` — die Größe, ein fertiges Paket aus CPU und Arbeitsspeicher. Das kleinste.

⚠️ **Das Passwort steht im Klartext** direkt in der Datei, die Sie in das Repository einchecken. Für eine Testumgebung zum Üben ist das in Ordnung, für ein Produktivsystem nicht: Dort liegt das Passwort in einem Secrets-Store, und die Beschreibung enthält nur einen Verweis darauf.

Weiter unten in derselben Datei steht ein `kind: Kafka`-Objekt.

**Was eine Warteschlange ist und warum sie hier steht.** Kafka ist eine Nachrichten-Warteschlange. Wenn die Anwendung eine Bestellung annimmt, tut sie zwei Dinge: Sie schreibt die Bestellung in die Datenbank und legt eine Nachricht in die Warteschlange — „Bestellung Nummer soundso ist eingegangen“. Von dort lesen andere Programme diese Nachricht — dasjenige, das dem Kunden eine E-Mail schickt, dasjenige, das Berichte zusammenrechnet. Der Sinn dieser Zwischenschicht ist, dass die Anwendung nicht wissen muss, wer sie wann liest: Sie hat die Nachricht abgelegt und ist weitergezogen. Falls ein Leser in diesem Moment gerade ausgefallen ist, wartet die Nachricht in der Warteschlange auf ihn.

In unserer Testumgebung gibt es keine Leser; die Warteschlange ist der Vollständigkeit halber da: Die Anwendung schreibt beim Erstellen einer Bestellung in sie hinein, und falls Kafka nicht verfügbar ist, meldet die Zustandsprüfung ehrlich, dass etwas nicht stimmt. Genau das passiert auch in einem echten System.
