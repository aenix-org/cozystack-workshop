## 28. Schritt 8: warum die Anwendung immer noch fehlschlägt

**Die Datenbank ist leer — die Anwendung braucht ihr Schema**

📍 **Wo:** in Ihrer eigenen Maschine — derjenigen, die Sie in Phase drei hochgefahren haben (app-VM). Nicht auf dem Bastion. Sie ist bereits im Cluster-Netzwerk und sieht die Datenbank über den Namen.

### Zuerst — eine zweite Prüfung, die ebenfalls fehlschlägt

Die Adressen haben wir korrigiert, die Anwendung ist neu gestartet und ihr Health-Endpoint antwortet mit `200`. Es sieht so aus, als wäre alles bereit. Versuchen wir, eine Bestellung anzulegen:

```bash
curl -s -X POST localhost:8080/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"item":"test order"}' -w '\nHTTP %{http_code}\n'
```

**Zurück kommt ein `500`.** Obwohl Health gerade eben noch `200` war.

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Weil die Health-Prüfung dieser Anwendung nur auf die **Tatsache einer Verbindung** zur Datenbank schaut: Die Verbindung wurde geöffnet, der Server hat geantwortet — also ist sie „lebendig“. Ob die benötigten Tabellen darin liegen, prüft sie nicht.

Und Tabellen gibt es keine. Als Sie Postgres aus dem Katalog bestellt haben, wurde Ihnen ein **leerer Server** übergeben: Die Datenbank `orders` und der Benutzer `orders` sind angelegt, und das war's. Auf der alten Maschine existierten die Tabellen — die Anwendung hat sie vor langer Zeit einmal beim ersten Start erzeugt, und über die Jahre hat es jeder vergessen.

Ganz nebenbei haben Sie gerade gesehen, was ein grüner Health-Check wert ist. Er sagt „Ich habe die Datenbank erreicht“, nicht „Ich funktioniere“. In einem echten Projekt lässt sich auf einer solchen Prüfung leicht ein Monitoring aufbauen, das munter alles grün anzeigt, während die Nutzer keine einzige Bestellung aufgeben können.

</details>

**Was wir tun.** Wir verlagern die Anwendung, nicht ihre Daten, deshalb müssen die Tabellen neu erstellt werden. Das geschieht einmal, mit einer Datei, die eine Liste von SQL-Befehlen enthält. Eine solche Datei nennt man **Schema** — sie beschreibt, wie der Speicher aufgebaut ist: welche Tabellen, welche Felder sie enthalten und von welchem Typ.

<details>
<summary><b>Genauer betrachtet: was in orders-schema.sql steckt</b></summary>

Die Datei ist `scripts/orders-schema.sql` im Repository. Sie enthält nur zwei Befehle.

**Der erste erzeugt die Bestelltabelle:**

```sql
CREATE TABLE IF NOT EXISTS orders (
    id           BIGSERIAL PRIMARY KEY,
    item         TEXT        NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'NEW',
    created_by   TEXT,
    processed_by TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);
```

Feld für Feld:

- `id BIGSERIAL PRIMARY KEY` — die Bestellnummer. `BIGSERIAL` bedeutet „die Datenbank vergibt die nächste in der Reihenfolge selbst“, `PRIMARY KEY` bedeutet „sie ist eindeutig und über sie wird die Zeile gefunden“.
- `item` — was bestellt wurde. `NOT NULL` — eine Bestellung ohne Artikel ergibt keinen Sinn, und die Datenbank akzeptiert eine solche Zeile nicht.
- `status` — der Zustand der Bestellung, standardmäßig `NEW`. Er wechselt zu `PROCESSED`, sobald die Nachricht durch Kafka gelaufen ist.
- `created_by` / `processed_by` — wer sie erstellt und wer sie verarbeitet hat. Genau hier schreibt die Anwendung `kafka` hinein, und an diesem Feld wird sich in Schritt 9 zeigen, dass die Warteschlange tatsächlich funktioniert.
- `created_at` / `processed_at` — wann. `TIMESTAMPTZ` — ein Zeitstempel mit Zeitzone.
- `IF NOT EXISTS` — „wenn die Tabelle bereits existiert, tue nichts und beschwere dich nicht“. Dank dessen lässt sich die Datei erneut anwenden, ohne etwas kaputtzumachen.

**Der zweite fügt eine Verlaufszeile hinzu:**

```sql
INSERT INTO orders (...) SELECT '12x rack rails', 'PROCESSED', ...
WHERE NOT EXISTS (SELECT 1 FROM orders);
```

Das ist kosmetisch: damit in Schritt 9 die Liste der Bestellungen nicht leer ist. `WHERE NOT EXISTS` bedeutet „füge nur ein, wenn die Tabelle leer ist“ — ein erneuter Lauf erzeugt kein Duplikat.

**Was in der Datei bewusst fehlt:** kein `CREATE DATABASE`, kein `CREATE USER`. Sowohl die Datenbank als auch die Rolle wurden bereits vom Cozystack-Katalog erstellt, als Sie in Schritt 5 Postgres bestellt haben. Genau das ist der Sinn eines Managed Service: Die Routine nimmt er auf sich, und für Sie bleibt nur Ihr eigenes Schema.

</details>

> ⚠️ **Widerspruch in den Kommentaren der Datei.** Im Kopf von `orders-schema.sql` steht, dass zuerst `GRANT CREATE,USAGE ON SCHEMA public` als Superuser nötig sei. **Das ist veraltet, tun Sie es nicht** — die Rolle `orders` gehört zu `orders_admin`, die die Datenbank und das Schema besitzt, sie hat die Rechte also bereits. Geprüft. Den Kommentar in der Datei korrigieren wir.
