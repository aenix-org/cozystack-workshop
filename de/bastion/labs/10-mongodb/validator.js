// Lab 10 · eine Regel zur Dokumentvalidierung (Schema-Validator) für die Collection passes.
//
// Ein Programm für mongosh — die MongoDB-Shell. Es läuft auf der VM,
// im Lab-Cluster, mit dem kurzen Befehl `mo` aus der README:
//     cd labs/10-mongodb && mo < validator.js
// Als Antwort sehen Sie die Zeile «правило установлено».
//
// Was ein Validierungsschema ist. Standardmäßig hat eine Collection kein Schema: die Datenbank akzeptiert
// ein Dokument beliebiger Form und speichert einen Tippfehler in einem Feldnamen («tipe» statt «type») stillschweigend —
// eine Lücke, die der Wächter am Kontrollpunkt nicht bemerkt. Ein Validator ist eine Beschreibung dessen, wie
// ein Dokument aussehen muss. Ab dem Moment der Anwendung prüft die Datenbank jede Einfügung und jede
// Änderung selbst.
//
// Was mit einem Dokument geschieht, das der Regel nicht entspricht: es wird nicht geschrieben,
// und die Operation gibt einen Fehler MongoServerError: Document failed validation zurück. Dokumente,
// die bereits in der Collection liegen, werden bei der Installation der Regel nicht geprüft und nicht
// neu geschrieben — aber ihre spätere Bearbeitung beginnt abgelehnt zu werden. Deshalb wird der Müll
// (Dokumente ohne Feld type) vor dem Anwenden dieser Datei entfernt, nicht danach.

// runCommand — sende einen Befehl direkt an die Datenbank und umgehe das übliche db.<collection>.<...>.
// collMod — «ändere die Einstellungen einer bestehenden Collection». Die Regel wird nachträglich an eine lebende
// Collection angehängt: es ist nicht nötig, die Datenbank zu stoppen und die Daten neu zu laden.
db.runCommand({
  collMod: "passes",
  // validator — die Regel selbst. $jsonSchema — eine Möglichkeit, die Form eines Dokuments zu beschreiben:
  // welche Felder erforderlich sind, welchen Typ sie haben und welche Werte erlaubt sind.
  validator: {
    $jsonSchema: {
      // Das Dokument der obersten Ebene selbst — ein Objekt.
      bsonType: "object",
      // Die Felder, ohne die ein Dokument nicht akzeptiert wird. Beachten Sie, was NICHT in der Liste steht:
      // guest. Ein Gruppenausweis hat eine Organisation anstelle eines Gastes, und die Regel muss
      // breit genug sein, damit die legitime Form des Dokuments durch sie
      // hindurchkommt. Die Einschränkung ist sofort spürbar: je vielfältiger die Dokumente,
      // desto weniger kann von allen gleichzeitig verlangt werden.
      required: ["type", "host"],
      // Anforderungen an einzelne Felder. Ein hier nicht aufgeführtes Feld wird in keiner Weise
      // geprüft — ein unbekanntes Feld gelangt in das Dokument. Das kann verboten werden
      // (additionalProperties: false), aber dann erfordert jedes neue Feld eine Änderung
      // der Regel, und Sie sind wieder bei einer Schema-Migration für jede Kleinigkeit. Wo die Grenze zu ziehen ist —
      // ist Ihre Entscheidung, und sie ist immer ein Kompromiss.
      properties: {
        // Der Ausweistyp — nur einer der vier aufgeführten Werte. Ein fünfter Typ
        // erfordert eine Änderung dieser Regel, und das ist gut: die Änderung wird bewusst.
        type: {
          enum: ["разовый", "недельный", "автомобильный", "групповой"],
          description: "тип пропуска, только из списка"
        },
        // Welcher Mitarbeiter den Ausweis bestellt hat. Das Feld ist erforderlich, und es muss eine
        // Zeichenkette sein.
        host: {
          bsonType: "string",
          description: "кто из сотрудников заказал"
        },
        // guest ist in properties, aber nicht in required: wenn das Feld im Dokument vorhanden ist,
        // muss es eine Zeichenkette sein; wenn es fehlt — ist das Dokument dennoch gültig.
        guest: {
          bsonType: "string"
        },
        // Regeln funktionieren auch innerhalb verschachtelter Objekte. Es gibt kein Feld car — keine
        // Anforderungen. Wenn es eines gibt — muss es ein Objekt sein, und das Kennzeichen des Autos darin
        // ist erforderlich, während der Anhänger, falls angegeben, — ein boolescher Wert ist, keine Zeichenkette
        // «нет».
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
        // members-Liste sein muss: name ist erforderlich, age — falls angegeben — eine ganze Zahl.
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
  // Durcheinander in Ruhe. Gerade mit moderate schaltet man die Validierung an einer Collection ein,
  // in der sich bereits Müll angesammelt hat: erst hört man auf, es weiter zu verschlimmern, dann repariert
  // man das Alte, dann wechselt man zu strict.
  validationLevel: "strict",
  // error — ein ungeeignetes Dokument ablehnen. Die Variante warn schreibt ins Protokoll und akzeptiert es
  // trotzdem: gut, um eine Woche lang zu beobachten, was hereinkommt, bevor man die
  // Ablehnung einschaltet und jemandes funktionierenden Code kaputt macht.
  validationAction: "error"
});

// runCommand antwortet mit einem Objekt, in dem Erfolg wie { ok: 1 } aussieht. Wir drucken
// unsere eigene Zeile, damit das Ergebnis der Anwendung der Datei auf einen Blick lesbar ist.
print("правило установлено");
