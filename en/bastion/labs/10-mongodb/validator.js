// Lab 10 · a document validation rule (schema validator) for the passes collection.
//
// A program for mongosh — the MongoDB shell. It runs on the VM,
// in the lab cluster, with the short command `mo` from the README:
//     cd labs/10-mongodb && mo < validator.js
// In response you will see the line «правило установлено».
//
// What a validation schema is. By default a collection has no schema: the database accepts
// a document of any shape and silently stores a typo in a field name («tipe» instead of «type») —
// a gap the guard at the checkpoint will not catch. A validator is a description of what
// a document must look like. From the moment it is applied, the database checks every insert and every
// change itself.
//
// What happens to a document that does not match the rule: it is not written,
// and the operation returns an error MongoServerError: Document failed validation. Documents
// that are already in the collection are not checked and not
// rewritten when the rule is installed — but a later edit of them will start being rejected. That is why the junk
// (documents without a type field) is removed before applying this file, not after.

// runCommand — send a command to the database directly, bypassing the usual db.<collection>.<...>.
// collMod — «change the settings of an existing collection». The rule is attached to a live
// collection after the fact: there is no need to stop the database and reload the data.
db.runCommand({
  collMod: "passes",
  // validator — the rule itself. $jsonSchema — a way to describe the shape of a document:
  // which fields are required, what type they are and which values are allowed.
  validator: {
    $jsonSchema: {
      // The top-level document itself — an object.
      bsonType: "object",
      // The fields without which a document is not accepted. Notice what is NOT in the list:
      // guest. A group pass has an organization instead of a guest, and the rule must
      // be broad enough for the legitimate form of the document to
      // pass through it. The constraint is felt immediately: the more varied the documents,
      // the less can be required of all of them at once.
      required: ["type", "host"],
      // Requirements for individual fields. A field not listed here is not checked
      // in any way — an unknown field will pass into the document. This can be forbidden
      // (additionalProperties: false), but then every new field will require editing
      // the rule, and you are back to a schema migration for every little thing. Where to draw the line —
      // is your decision, and it is always a compromise.
      properties: {
        // The pass type — only one of the four listed values. A fifth type
        // will require changing this rule, and that is good: the change will become deliberate.
        type: {
          enum: ["разовый", "недельный", "автомобильный", "групповой"],
          description: "тип пропуска, только из списка"
        },
        // Which employee ordered the pass. The field is required, and it must be
        // a string.
        host: {
          bsonType: "string",
          description: "кто из сотрудников заказал"
        },
        // guest is in properties, but not in required: if the field is present in the document,
        // it must be a string; if it is absent — the document is still valid.
        guest: {
          bsonType: "string"
        },
        // Rules work inside nested objects too. There is no car field — no
        // requirements. If there is one — it must be an object, and the car plate in it
        // is required, while the trailer, if specified, — is a boolean value, not the string
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
        // And inside lists. items describes what each element of the
        // members list must be: name is required, age — if specified — an integer.
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
  // strict — check all inserts and all changes. The softer variant moderate
  // checks new documents and edits of those that already match the rule, and leaves the old
  // mishmash alone. It is precisely with moderate that you turn on validation on a collection
  // that has already accumulated junk: first stop making it worse, then fix
  // the old, then switch to strict.
  validationLevel: "strict",
  // error — reject an unsuitable document. The warn variant writes to the log and still
  // accepts it: good for spending a week watching what comes in, before turning on
  // rejection and breaking someone's working code.
  validationAction: "error"
});

// runCommand replies with an object in which success looks like { ok: 1 }. We print
// our own line so that the result of applying the file reads at a glance.
print("правило установлено");
