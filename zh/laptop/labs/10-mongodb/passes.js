// Lab 10 · four passes of four different shapes in the passes collection.
//
// This is not a settings file but a program for mongosh — the MongoDB shell, which
// understands JavaScript. It runs on your laptop, in the lab cluster, with the short
// `mo` command from the README (it launches mongosh inside the working pod):
//     cd labs/10-mongodb && mo < passes.js
// In response you will see the line "documents in collection: 4".
//
// Run the file twice and there will be eight documents: insertMany only adds.

// db is the database you are connected to; passes is a collection in it (the closest
// analogue of a table); insertMany means "add these documents". You do not need to
// create any table in advance, and there is nowhere to describe the fields: the
// collection appears at the moment of the first insert, and by default the database
// has no opinion about which fields a document may have.
// That is why the four documents below have different sets of fields and yet lie side
// by side, in one collection. This is exactly why the document model exists: no empty
// columns, no four tables for four pass types, no fifth one to link them together.
db.passes.insertMany([
  {
    // A single-visit pass — the shortest shape: six fields, all simple values.
    // In an ordinary table this would be an ordinary row.
    // ISODate(...) is not a string but a date. MongoDB stores documents in the binary
    // BSON format, where a value has a type: date, integer, float, boolean.
    // A date can be compared and sorted; the string "2026-09-01" only if you are
    // lucky with how it was written.
    type: "single-use",
    guest: "James P. Whitfield",
    host: "petrov@corp.example",
    entrance: "North",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "job interview"
  },
  {
    // A weekly pass. Instead of valid_on there is a pair valid_from and valid_to, and
    // instead of a single entrance a list of entrances right there in the field. In a
    // table such a list would require either a separate "pass — entrance" table, or a
    // comma-separated string that you then cannot search properly.
    // A badge_returned field has appeared, which the single-visit pass does not have
    // at all: not NULL and not empty, but simply no such field in that document. These
    // are different things, and they are searched for differently.
    type: "weekly",
    guest: "Emma L. Prescott",
    host: "petrov@corp.example",
    entrances: ["North", "South"],
    valid_from: ISODate("2026-09-01T00:00:00Z"),
    valid_to: ISODate("2026-09-07T23:59:59Z"),
    purpose: "external audit",
    badge_returned: false
  },
  {
    // A vehicle pass. Everything related to the car lives inside a single field car.
    // This is not a string with JSON inside, but a full nested structure: you can
    // search by car.plate and build an index on it.
    type: "vehicle",
    guest: "Victor S. Marsh",
    host: "logistics@corp.example",
    entrance: "West",
    valid_on: ISODate("2026-09-02T07:30:00Z"),
    car: {
      plate: "AB-1174-CD",
      model: "Ford Transit",
      trailer: false,
      weight_kg: 3500
    },
    parking: "P2"
  },
  {
    // A group pass. Here there is a list of objects: each member has their own fields,
    // and the length of the list is arbitrary.
    // And most importantly — this document has no guest field at all: instead of a
    // guest there is an organization and a contact person. The shape differs from the
    // others not by one field but in essence. This will echo later in the lab: the
    // document validation rule will not be able to require guest from everyone,
    // otherwise a legitimate group pass would not pass.
    type: "group",
    organization: "City High School No. 1",
    contact: "Olivia W. Grant",
    host: "hr@corp.example",
    entrance: "North",
    valid_on: ISODate("2026-09-03T10:00:00Z"),
    escort: "Alan A. Foster",
    members: [
      { name: "Peter Hale", age: 16 },
      { name: "Mary Fenwick", age: 15 },
      { name: "Isaac Hart", age: 17 }
    ]
  }
]);

// countDocuments({}) — count the documents matching a condition; an empty condition
// means "all". The print is needed so the file has a visible result: insertMany itself
// replies with a list of issued identifiers, and in it you can easily miss how many
// documents actually landed.
print("documents in collection: " + db.passes.countDocuments({}));
