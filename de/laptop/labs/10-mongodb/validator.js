// Lab 10 · Dokumenten-Prüfregel (Schema-Validator) für die Collection passes.
//
// Ein Programm für mongosh — die MongoDB-Shell. Läuft auf dem Laptop,
// im Lab-Cluster, mit dem kurzen Befehl `mo` aus der README:
//     cd labs/10-mongodb && mo < validator.js
// Als Antwort sehen Sie die Zeile «Regel installiert».
//
// Was ein Prüfschema ist. Standardmäßig hat eine Collection kein Schema: die Datenbank nimmt
// ein Dokument beliebiger Form an und legt einen Tippfehler im Feldnamen («tipe» statt «type») still ab —
// ein solches Versehen findet der Wächter am Kontrollpunkt nicht. Ein Validator ist eine Beschreibung dessen,
// wie ein Dokument sein muss. Ab dem Moment der Anwendung prüft die Datenbank jede Einfügung und jede
// Änderung selbst.
//
// Was mit einem Dokument geschieht, das der Regel nicht entspricht: es wird nicht geschrieben,
// und die Operation gibt einen MongoServerError: Document failed validation zurück. Dokumente,
// die bereits in der Collection liegen, werden beim Anwenden der Regel nicht geprüft und nicht
// umgeschrieben — aber ihre nachträgliche Bearbeitung wird dann abgelehnt. Deshalb wird Müll
// (Dokumente ohne das Feld type) vor dem Anwenden dieser Datei entfernt, nicht danach.

// runCommand — der Datenbank einen Befehl direkt senden, unter Umgehung des üblichen db.<collection>.<...>.
// collMod — «ändere die Einstellungen einer bestehenden Collection». Die Regel wird einer laufenden
// Collection nachträglich angehängt: die Datenbank stoppen oder Daten umlagern ist nicht nötig.
db.runCommand({
  collMod: "passes",
  // validator — die Regel selbst. $jsonSchema — eine Art, die Form eines Dokuments zu beschreiben:
  // welche Felder Pflicht sind, welchen Typs sie sind und welche Werte zulässig sind.
  validator: {
    $jsonSchema: {
      // Das Dokument der obersten Ebene selbst ist ein Objekt.
      bsonType: "object",
      // Felder, ohne die das Dokument nicht angenommen wird. Beachten Sie, was NICHT in der Liste steht:
      // guest. Ein Gruppenpass hat statt eines Gastes eine Organisation, und die Regel muss
      // breit genug sein, dass eine legitime Dokumentform durch sie
      // hindurchgeht. Die Einschränkung ist sofort spürbar: je vielfältiger die Dokumente,
      // desto weniger kann man von allen zugleich verlangen.
      required: ["type", "host"],
      // Anforderungen an einzelne Felder. Ein Feld, das hier nicht steht, wird gar nicht
      // geprüft — ein unbekanntes Feld gelangt ins Dokument. Verbieten kann man das
      // (additionalProperties: false), aber dann erfordert jedes neue Feld eine Änderung
      // der Regel, und Sie sind zurück bei der Schema-Migration bei jedem Niesen. Wo die Grenze zu ziehen ist —
      // ist Ihre Entscheidung, und sie ist immer ein Kompromiss.
      properties: {
        // Der Pass-Typ — nur einer der vier aufgeführten Werte. Ein fünfter Typ
        // erfordert eine Änderung dieser Regel, und das ist gut: die Änderung wird bewusst.
        type: {
          enum: ["Einmalausweis", "Wochenausweis", "Fahrzeugausweis", "Gruppenausweis"],
          description: "Ausweistyp, nur aus der erlaubten Liste"
        },
        // Welcher Mitarbeiter den Pass bestellt hat. Das Feld ist Pflicht, und es muss eine
        // Zeichenkette sein.
        host: {
          bsonType: "string",
          description: "welcher Mitarbeiter die Bestellung aufgegeben hat"
        },
        // guest steht in properties, aber nicht in required: wenn das Feld im Dokument vorhanden ist,
        // muss es eine Zeichenkette sein; wenn es fehlt — ist das Dokument dennoch gültig.
        guest: {
          bsonType: "string"
        },
        // Regeln funktionieren auch innerhalb verschachtelter Objekte. Es gibt kein Feld car — keine
        // Anforderungen. Gibt es eines — muss es ein Objekt sein, und das Kennzeichen des Wagens darin
        // ist Pflicht, während der Anhänger, falls angegeben, ein Boolescher Wert ist, keine Zeichenkette
        // „nein“.
        car: {
          bsonType: "object",
          required: ["plate"],
          properties: {
            plate: { bsonType: "string" },
            model: { bsonType: "string" },
            trailer: { bsonType: "bool" },
            weight_kg: { bsonType: ["int", "long", "double"] }
          }
        },
        // Und innerhalb von Listen. items beschreibt, wie jedes Element der
        // Teilnehmerliste sein muss: name ist Pflicht, age — falls angegeben — eine ganze Zahl.
        members: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["name"],
            properties: {
              name: { bsonType: "string" },
              age: { bsonType: ["int", "long", "double"] }
            }
          }
        }
      }
    }
  },
  // strict — alle Einfügungen und alle Änderungen prüfen. Die weichere Variante moderate
  // prüft neue Dokumente und Bearbeitungen jener, die der Regel bereits entsprechen, und lässt das alte
  // Durcheinander in Ruhe. Genau mit moderate schaltet man die Prüfung auf einer Collection ein,
  // in der sich bereits Müll angesammelt hat: zuerst hören wir auf, es weiter zu verderben, dann reparieren wir
  // das Alte, dann gehen wir zu strict über.
  validationLevel: "strict",
  // error — ein ungeeignetes Dokument ablehnen. Die Variante warn schreibt ins Protokoll und nimmt es
  // trotzdem an: geeignet, um eine Woche lang zu beobachten, was hereinkommt, bevor man die
  // Ablehnung einschaltet und jemandes funktionierenden Code kaputtmacht.
  validationAction: "error"
});

// runCommand antwortet mit einem Objekt, in dem der Erfolg wie { ok: 1 } aussieht. Wir drucken
// unsere eigene Zeile, damit das Ergebnis der Anwendung der Datei auf einen Blick lesbar ist.
print("Regel installiert");
