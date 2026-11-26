// Lab 10 · document validation rule (schema validator) for the passes collection.
//
// A program for mongosh — the MongoDB shell. Runs on the laptop,
// in the lab cluster, with the short command `mo` from the README:
//     cd labs/10-mongodb && mo < validator.js
// In response you will see the line «rule installed».
//
// What a validation schema is. By default a collection has no schema: the database accepts
// a document of any shape and silently stores a typo in a field name («tipe» instead of «type») —
// such an omission the guard at the checkpoint won't catch. A validator is a description of what
// a document must be. From the moment it is applied, the database checks every insert and every
// change itself.
//
// What happens to a document that does not match the rule: it will not be written,
// and the operation returns a MongoServerError: Document failed validation. Documents
// already in the collection are not checked and not rewritten when the rule is applied —
// but subsequent edits to them will start being rejected. That is why junk
// (documents without a type field) is removed before applying this file, not after.

// runCommand — send a command to the database directly, bypassing the usual db.<collection>.<...>.
// collMod — «change the settings of an existing collection». The rule is attached to a live
// collection after the fact: no need to stop the database or migrate the data.
db.runCommand({
  collMod: "passes",
  // validator — the rule itself. $jsonSchema — a way to describe the shape of a document:
  // which fields are required, of what type, and what values are allowed.
  validator: {
    $jsonSchema: {
      // The top-level document itself is an object.
      bsonType: "object",
      // Fields without which the document will not be accepted. Note what is NOT in the list:
      // guest. A group pass has an organization instead of a guest, and the rule must
      // be broad enough that a legitimate document shape passes through it.
      // The constraint is felt immediately: the more varied the documents,
      // the less you can demand of all of them at once.
      required: ["type", "host"],
      // Requirements for individual fields. A field not listed here is not checked
      // at all — an unknown field will pass into the document. You can forbid this
      // (additionalProperties: false), but then every new field will require editing
      // the rule, and you are back to migrating the schema at every sneeze. Where to draw the line —
      // is your decision, and it is always a compromise.
      properties: {
        // The pass type — only one of the four listed values. A fifth type
        // will require changing this rule, and that is good: the change becomes deliberate.
        type: {
          enum: ["single-use", "weekly", "vehicle", "group"],
          description: "pass type, from the allowed list only"
        },
        // Which employee ordered the pass. The field is required, and it must be
        // a string.
        host: {
          bsonType: "string",
          description: "which employee placed the order"
        },
        // guest is in properties but not in required: if the field is present in the document,
        // it must be a string; if it is absent — the document is still valid.
        guest: {
          bsonType: "string"
        },
        // Rules also work inside nested objects. There is no car field — no
        // requirements. If there is one — it must be an object, and the car plate in it
        // is required, while the trailer, if specified, is a boolean, not the string
        // «no».
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
  // strict — check all inserts and all changes. The softer moderate option
  // checks new documents and edits to those that already match the rule, and leaves the old
  // mishmash alone. It is precisely with moderate that you enable validation on a collection
  // that has already accumulated junk: first we stop making it worse, then we fix
  // the old, then we switch to strict.
  validationLevel: "strict",
  // error — reject an unsuitable document. The warn option logs it and still
  // accepts: good for watching for a week what comes in, before turning on
  // rejection and breaking someone's working code.
  validationAction: "error"
});

// runCommand replies with an object in which success looks like { ok: 1 }. We print
// our own line so the result of applying the file reads at a glance.
print("rule installed");
