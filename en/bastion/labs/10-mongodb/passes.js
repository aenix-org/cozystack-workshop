// Lab 10 · four passes of four different shapes in the passes collection.
//
// This is not a config file but a program for mongosh — the MongoDB shell, which
// understands JavaScript. It runs on the VM, in the lab cluster, via the short
// command `mo` from the README (it launches mongosh inside the working pod):
//     cd labs/10-mongodb && mo < passes.js
// In response you will see the line «документов в коллекции: 4».
//
// Run the file twice and there will be eight documents: insertMany only appends.

// db is the database you are connected to; passes is a collection in it (the closest
// analog of a table); insertMany means «add these documents». No table needs to be
// created in advance and there is nowhere to describe fields: the collection appears
// at the moment of the first insert, and by default the database has no opinion about
// which fields a document may have.
// That is why the four documents below have different sets of fields yet lie side by
// side, in one collection. This is exactly what the document model exists for: no empty
// columns, no four tables for four pass types, no fifth one to link them.
db.passes.insertMany([
  {
    // A single-entry pass — the shortest shape: six fields, all simple values.
    // In an ordinary table this would be an ordinary row.
    // ISODate(...) is not a string but exactly a date. MongoDB stores documents in the
    // binary BSON format, where a value has a type: date, integer, float, boolean.
    // By date you can compare and sort; by the string «2026-09-01» only if you got
    // lucky with the recording format.
    type: "разовый",
    guest: "Иванов Иван Иванович",
    host: "petrov@corp.ru",
    entrance: "Северная",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "собеседование"
  },
  {
    // A weekly pass. Instead of valid_on there is a pair valid_from and valid_to,
    // instead of a single entrance a list of entrances right in the field. In a table
    // such a list would need either a separate «pass — entrance» table, or a
    // comma-separated string that you then cannot search properly.
    // A badge_returned field has appeared, which the single-entry pass does not have at
    // all: not NULL and not empty, but literally no such field in that document. These
    // are different things, and they are searched for differently.
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
    // A vehicle pass. Everything related to the car lies inside a single field
    // car. This is not a string with JSON inside but a full-fledged nested structure:
    // by car.plate you can search and build an index on it.
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
    // A group pass. Here there is a list of objects: each member has its own fields,
    // the length of the list is arbitrary.
    // And most importantly — this document has no guest field at all: instead of a
    // guest, an organization and a contact person. The shape differs from the others
    // not by one field but in essence. This will echo further in the lab: the document
    // validation rule will not be able to require guest from everyone, otherwise a
    // legitimate group pass would not pass.
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

// countDocuments({}) counts documents matching a condition; an empty condition means
// «all». The print is needed so the file has a visible result: insertMany itself
// responds with a list of issued identifiers, and in it it is easy to miss how many
// documents actually landed.
print("документов в коллекции: " + db.passes.countDocuments({}));
