// Lab 10 · vier Ausweise in vier verschiedenen Formen in der Collection passes.
//
// Dies ist keine Konfigurationsdatei, sondern ein Programm für mongosh — die MongoDB-Shell,
// die JavaScript versteht. Es läuft auf Ihrem Laptop, im Lab-Cluster, mit dem kurzen
// Befehl `mo` aus der README (er startet mongosh innerhalb des Arbeits-Pods):
//     cd labs/10-mongodb && mo < passes.js
// Als Antwort sehen Sie die Zeile «документов в коллекции: 4».
//
// Führen Sie die Datei zweimal aus, und es werden acht Dokumente: insertMany fügt nur hinzu.

// db ist die Datenbank, mit der Sie verbunden sind; passes ist eine Collection darin (das
// nächste Analogon einer Tabelle); insertMany bedeutet «füge diese Dokumente hinzu». Sie
// müssen keine Tabelle im Voraus anlegen, und es gibt keinen Ort, um die Felder zu
// beschreiben: die Collection entsteht im Moment der ersten Einfügung, und die Datenbank hat
// standardmäßig keine Meinung darüber, welche Felder ein Dokument haben darf.
// Deshalb haben die vier Dokumente unten unterschiedliche Feldsätze und liegen dennoch
// nebeneinander, in einer Collection. Genau dafür existiert das Dokumentmodell: keine leeren
// Spalten, keine vier Tabellen für vier Ausweistypen, keine fünfte, die sie verbindet.
db.passes.insertMany([
  {
    // Einmal-Ausweis — die kürzeste Form: sechs Felder, alle einfache Werte.
    // In einer gewöhnlichen Tabelle wäre das eine gewöhnliche Zeile.
    // ISODate(...) ist keine Zeichenkette, sondern eben ein Datum. MongoDB speichert Dokumente
    // im binären BSON-Format, wo ein Wert einen Typ hat: Datum, Ganzzahl, Fließkomma, Boolean.
    // Nach dem Datum kann man vergleichen und sortieren, nach der Zeichenkette «2026-09-01» nur,
    // wenn man mit dem Format der Aufzeichnung Glück hatte.
    type: "разовый",
    guest: "Иванов Иван Иванович",
    host: "petrov@corp.ru",
    entrance: "Северная",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "собеседование"
  },
  {
    // Wochen-Ausweis. Statt valid_on gibt es ein Paar valid_from und valid_to, statt eines
    // einzelnen Eingangs eine Liste entrances direkt im Feld. In einer Tabelle würde eine solche
    // Liste entweder eine separate Tabelle «Ausweis — Eingang» oder eine Zeichenkette mit
    // Kommas erfordern, nach der man dann nicht mehr richtig suchen kann.
    // Ein Feld badge_returned ist aufgetaucht, das der Einmal-Ausweis gar nicht hat:
    // nicht NULL und nicht leer, sondern eben kein solches Feld in jenem Dokument. Das sind
    // verschiedene Dinge, und sie werden unterschiedlich gesucht.
    type: "недельный",
    guest: "Сидорова Анна Петровна",
    host: "petrov@corp.ru",
    entrances: ["Северная", "Южная"],
    valid_from: ISODate("2026-09-01T00:00:00Z"),
    valid_to: ISODate("2026-09-07T23:59:59Z"),
    purpose: "внешний аудит",
    badge_returned: false
  },
  {
    // Fahrzeug-Ausweis. Alles, was das Auto betrifft, liegt innerhalb eines einzigen Feldes
    // car. Das ist keine Zeichenkette mit JSON darin, sondern eine vollwertige verschachtelte
    // Struktur: nach car.plate kann man suchen und darauf einen Index aufbauen.
    type: "автомобильный",
    guest: "Кузнецов Виктор Сергеевич",
    host: "logistics@corp.ru",
    entrance: "Западная",
    valid_on: ISODate("2026-09-02T07:30:00Z"),
    car: {
      plate: "А123ВС174",
      model: "ГАЗель Next",
      trailer: false,
      weight_kg: 3500
    },
    parking: "P2"
  },
  {
    // Gruppen-Ausweis. Hier eine Liste von Objekten: jeder Teilnehmer hat seine eigenen Felder,
    // die Länge der Liste ist beliebig.
    // Und das Wichtigste — dieses Dokument hat gar kein Feld guest: statt eines Gastes
    // eine Organisation und eine Kontaktperson. Die Form unterscheidet sich von den übrigen
    // nicht durch ein Feld, sondern im Wesen. Weiter im Lab wird das nachhallen: die
    // Dokument-Prüfregel wird guest nicht von allen verlangen können, sonst käme ein
    // legitimer Gruppen-Ausweis nicht durch.
    type: "групповой",
    organization: "Гимназия № 1",
    contact: "Смирнова Ольга Владимировна",
    host: "hr@corp.ru",
    entrance: "Северная",
    valid_on: ISODate("2026-09-03T10:00:00Z"),
    escort: "Петров Алексей Алексеевич",
    members: [
      { name: "Орлов Пётр", age: 16 },
      { name: "Волкова Мария", age: 15 },
      { name: "Зайцев Илья", age: 17 }
    ]
  }
]);

// countDocuments({}) — zählt die Dokumente, die eine Bedingung erfüllen; eine leere Bedingung
// bedeutet «alle». Die Ausgabe ist nötig, damit die Datei ein sichtbares Ergebnis hat: insertMany
// selbst antwortet mit einer Liste der ausgegebenen Bezeichner, und darin kann man leicht
// übersehen, wie viele Dokumente tatsächlich abgelegt wurden.
print("документов в коллекции: " + db.passes.countDocuments({}));
