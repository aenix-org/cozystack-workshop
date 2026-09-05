// Lab 10 · vier Ausweise vier verschiedener Formen in der Collection passes.
//
// Das ist keine Konfigurationsdatei, sondern ein Programm für mongosh — die MongoDB-Shell,
// die JavaScript versteht. Es läuft auf der VM, im Lab-Cluster, über den kurzen
// Befehl `mo` aus der README (er startet mongosh innerhalb des Arbeits-Pods):
//     cd labs/10-mongodb && mo < passes.js
// Als Antwort sehen Sie die Zeile «Dokumente in der Sammlung: 4».
//
// Führen Sie die Datei zweimal aus, und es werden acht Dokumente: insertMany hängt nur an.

// db ist die Datenbank, mit der Sie verbunden sind; passes ist eine Collection darin (das
// nächste Analogon einer Tabelle); insertMany bedeutet «füge diese Dokumente hinzu». Es muss
// keine Tabelle im Voraus angelegt werden und es gibt nirgends einen Ort, Felder zu beschreiben:
// die Collection entsteht im Moment des ersten Einfügens, und standardmäßig hat die Datenbank
// keine Meinung darüber, welche Felder ein Dokument haben darf.
// Deshalb haben die vier Dokumente unten unterschiedliche Feldsätze und liegen dennoch Seite an
// Seite, in einer Collection. Genau dafür existiert das Dokumentenmodell: keine leeren Spalten,
// keine vier Tabellen für vier Ausweistypen, keine fünfte, die sie verknüpft.
db.passes.insertMany([
  {
    // Ein Einmal-Ausweis — die kürzeste Form: sechs Felder, alle einfache Werte.
    // In einer gewöhnlichen Tabelle wäre das eine gewöhnliche Zeile.
    // ISODate(...) ist keine Zeichenkette, sondern genau ein Datum. MongoDB speichert Dokumente im
    // binären BSON-Format, in dem ein Wert einen Typ hat: Datum, Ganzzahl, Fließkommazahl, Boolean.
    // Nach Datum kann man vergleichen und sortieren; nach der Zeichenkette «2026-09-01» nur, wenn
    // man mit dem Aufzeichnungsformat Glück hatte.
    type: "Einmalausweis",
    guest: "Johannes M. Weber",
    host: "petrov@corp.example",
    entrance: "Nord",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "Vorstellungsgespräch"
  },
  {
    // Ein Wochen-Ausweis. Statt valid_on gibt es ein Paar valid_from und valid_to, statt
    // eines einzelnen Eingangs eine Liste entrances direkt im Feld. In einer Tabelle würde
    // eine solche Liste entweder eine separate Tabelle «Ausweis — Eingang» benötigen oder eine
    // durch Kommas getrennte Zeichenkette, nach der man dann nicht mehr richtig suchen kann.
    // Ein Feld badge_returned ist aufgetaucht, das der Einmal-Ausweis überhaupt nicht hat:
    // nicht NULL und nicht leer, sondern buchstäblich kein solches Feld in diesem Dokument. Das sind
    // verschiedene Dinge, und sie werden unterschiedlich gesucht.
    type: "Wochenausweis",
    guest: "Anna L. Bergmann",
    host: "petrov@corp.example",
    entrances: ["Nord", "Süd"],
    valid_from: ISODate("2026-09-01T00:00:00Z"),
    valid_to: ISODate("2026-09-07T23:59:59Z"),
    purpose: "externe Prüfung",
    badge_returned: false
  },
  {
    // Ein Fahrzeug-Ausweis. Alles, was das Auto betrifft, liegt innerhalb eines einzigen Feldes
    // car. Das ist keine Zeichenkette mit JSON darin, sondern eine vollwertige verschachtelte Struktur:
    // nach car.plate kann man suchen und darauf einen Index aufbauen.
    type: "Fahrzeugausweis",
    guest: "Viktor S. Schmidt",
    host: "logistics@corp.example",
    entrance: "West",
    valid_on: ISODate("2026-09-02T07:30:00Z"),
    car: {
      plate: "M-AB 1234",
      model: "Ford Transit",
      trailer: false,
      weight_kg: 3500
    },
    parking: "P2"
  },
  {
    // Ein Gruppen-Ausweis. Hier eine Liste von Objekten: jeder Teilnehmer hat seine eigenen Felder,
    // die Länge der Liste ist beliebig.
    // Und am wichtigsten — dieses Dokument hat gar kein Feld guest: statt eines Gastes
    // eine Organisation und eine Kontaktperson. Die Form unterscheidet sich von den anderen nicht durch
    // ein Feld, sondern im Wesen. Weiter in der Lab wird sich das auswirken: die Regel zur Prüfung von
    // Dokumenten wird guest nicht von allen verlangen können, sonst käme ein rechtmäßiger
    // Gruppen-Ausweis nicht durch.
    type: "Gruppenausweis",
    organization: "Gymnasium Nr. 1",
    contact: "Olivia W. Fischer",
    host: "hr@corp.example",
    entrance: "Nord",
    valid_on: ISODate("2026-09-03T10:00:00Z"),
    escort: "Alexander A. Fuchs",
    members: [
      { name: "Peter Adler", age: 16 },
      { name: "Maria Wolf", age: 15 },
      { name: "Elias Hartmann", age: 17 }
    ]
  }
]);

// countDocuments({}) — Dokumente zählen, die einer Bedingung entsprechen; eine leere Bedingung
// bedeutet «alle». Die Ausgabe wird gebraucht, damit die Datei ein sichtbares Ergebnis hat: insertMany
// selbst antwortet mit einer Liste der vergebenen Bezeichner, und darin übersieht man leicht, wie viele
// Dokumente tatsächlich abgelegt wurden.
print("Dokumente in der Sammlung: " + db.passes.countDocuments({}));
