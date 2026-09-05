// Lab 10 · cuatro pases de cuatro formas distintas en la colección passes.
//
// Esto no es un archivo de configuración, sino un programa para mongosh — el shell de
// MongoDB, que entiende JavaScript. Se ejecuta en la máquina virtual, en el clúster de
// laboratorio, con el comando corto `mo` del README (lanza mongosh dentro del pod de
// trabajo):
//     cd labs/10-mongodb && mo < passes.js
// En respuesta verás la línea «documentos en la colección: 4».
//
// Ejecuta el archivo dos veces y habrá ocho documentos: insertMany solo añade.

// db es la base de datos a la que estás conectado; passes es una colección en ella (el
// análogo más cercano de una tabla); insertMany significa «añade estos documentos». No
// hace falta crear ninguna tabla de antemano y no hay dónde describir los campos: la
// colección aparece en el momento de la primera inserción, y por defecto la base de datos
// no tiene ninguna opinión sobre qué campos puede tener un documento.
// Por eso los cuatro documentos de abajo tienen conjuntos de campos distintos y aun así
// yacen uno al lado del otro, en una sola colección. Para esto existe precisamente el
// modelo documental: ni columnas vacías, ni cuatro tablas para cuatro tipos de pase, ni
// una quinta que los vincule.
db.passes.insertMany([
  {
    // Un pase de entrada única — la forma más corta: seis campos, todos valores simples.
    // En una tabla ordinaria esto sería una fila ordinaria.
    // ISODate(...) no es una cadena, sino precisamente una fecha. MongoDB almacena los
    // documentos en el formato binario BSON, donde un valor tiene un tipo: fecha, entero,
    // decimal, booleano.
    // Por fecha se puede comparar y ordenar; por la cadena «2026-09-01» solo si tuviste
    // suerte con el formato de escritura.
    type: "puntual",
    guest: "Javier P. Herrera",
    host: "petrov@corp.example",
    entrance: "Norte",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "entrevista de trabajo"
  },
  {
    // Un pase semanal. En lugar de valid_on hay un par valid_from y valid_to, en lugar de
    // una sola entrada una lista de entrances directamente en el campo. En una tabla, para
    // tal lista haría falta o bien una tabla aparte «pase — entrada», o bien una cadena
    // con comas por la que luego no se puede buscar como es debido.
    // Ha aparecido un campo badge_returned, que el pase de entrada única no tiene en
    // absoluto: no es NULL ni está vacío, sino que literalmente no existe tal campo en ese
    // documento. Son cosas distintas, y se buscan de forma distinta.
    type: "semanal",
    guest: "Elena L. Prado",
    host: "petrov@corp.example",
    entrances: ["Norte", "Sur"],
    valid_from: ISODate("2026-09-01T00:00:00Z"),
    valid_to: ISODate("2026-09-07T23:59:59Z"),
    purpose: "auditoría externa",
    badge_returned: false
  },
  {
    // Un pase de vehículo. Todo lo relativo al coche yace dentro de un único campo
    // car. Esto no es una cadena con JSON dentro, sino una estructura anidada de pleno
    // derecho: por car.plate se puede buscar y construir un índice sobre él.
    type: "vehicular",
    guest: "Víctor S. Marín",
    host: "logistics@corp.example",
    entrance: "Oeste",
    valid_on: ISODate("2026-09-02T07:30:00Z"),
    car: {
      plate: "1174 BCD",
      model: "Ford Transit",
      trailer: false,
      weight_kg: 3500
    },
    parking: "P2"
  },
  {
    // Un pase de grupo. Aquí hay una lista de objetos: cada participante tiene sus propios
    // campos, la longitud de la lista es arbitraria.
    // Y lo más importante — este documento no tiene campo guest en absoluto: en lugar de un
    // invitado, una organización y una persona de contacto. La forma difiere de las demás
    // no en un campo, sino en esencia. Esto tendrá eco más adelante en la lab: la regla de
    // validación de documentos no podrá exigir guest a todos, de lo contrario un pase de
    // grupo legítimo no pasaría.
    type: "grupal",
    organization: "Instituto Municipal N.º 1",
    contact: "Olivia V. Serrano",
    host: "hr@corp.example",
    entrance: "Norte",
    valid_on: ISODate("2026-09-03T10:00:00Z"),
    escort: "Alejandro A. Fuentes",
    members: [
      { name: "Pedro Álvarez", age: 16 },
      { name: "María Vega", age: 15 },
      { name: "Isaac Ferrer", age: 17 }
    ]
  }
]);

// countDocuments({}) cuenta los documentos que cumplen una condición; una condición vacía
// significa «todos». La impresión hace falta para que el archivo tenga un resultado
// visible: insertMany mismo responde con una lista de identificadores emitidos, y en ella
// es fácil no percibir cuántos documentos realmente quedaron.
print("documentos en la colección: " + db.passes.countDocuments({}));
