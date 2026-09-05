// Lab 10 · cuatro pases de cuatro formas distintas en la colección passes.
//
// Esto no es un archivo de configuración, sino un programa para mongosh — la shell de
// MongoDB, que entiende JavaScript. Se ejecuta en el portátil, en el clúster de
// laboratorio, con el comando corto `mo` del README (lanza mongosh dentro del pod de
// trabajo):
//     cd labs/10-mongodb && mo < passes.js
// En respuesta verás la línea «documentos en la colección: 4».
//
// Ejecuta el archivo dos veces y habrá ocho documentos: insertMany solo añade.

// db es la base de datos a la que estás conectado; passes es una colección en ella (el
// análogo más cercano a una tabla); insertMany significa «añade estos documentos». No
// necesitas crear ninguna tabla de antemano y no hay dónde describir los campos: la
// colección aparece en el momento de la primera inserción, y por defecto la base de datos
// no tiene opinión sobre qué campos puede tener un documento.
// Por eso los cuatro documentos de abajo tienen distintos conjuntos de campos y aun así
// están juntos, en una sola colección. Para esto existe el modelo documental: ni columnas
// vacías, ni cuatro tablas para cuatro tipos de pase, ni una quinta que los enlace.
db.passes.insertMany([
  {
    // Pase de una sola visita — la forma más corta: seis campos, todos valores simples.
    // En una tabla común esto sería una fila común.
    // ISODate(...) no es una cadena, sino precisamente una fecha. MongoDB almacena los
    // documentos en formato binario BSON, donde un valor tiene tipo: fecha, entero,
    // decimal, booleano. Por la fecha se puede comparar y ordenar; por la cadena
    // «2026-09-01» solo si tienes suerte con cómo se escribió.
    type: "puntual",
    guest: "Javier P. Herrera",
    host: "petrov@corp.example",
    entrance: "Norte",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "entrevista de trabajo"
  },
  {
    // Pase semanal. En lugar de valid_on hay un par valid_from y valid_to, y en lugar de
    // una sola entrada una lista de entrances directamente en el campo. En una tabla, una
    // lista así requeriría o bien una tabla aparte «pase — entrada», o bien una cadena
    // separada por comas por la que luego no se puede buscar bien.
    // Ha aparecido un campo badge_returned, que el pase de una sola visita no tiene en
    // absoluto: ni NULL ni vacío, sino simplemente no existe tal campo en ese documento.
    // Son cosas distintas, y se buscan de forma distinta.
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
    // Pase de vehículo. Todo lo relacionado con el coche vive dentro de un único campo
    // car. No es una cadena con JSON dentro, sino una estructura anidada completa: se
    // puede buscar por car.plate y construir un índice sobre él.
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
    // Pase de grupo. Aquí hay una lista de objetos: cada participante tiene sus propios
    // campos, y la longitud de la lista es arbitraria.
    // Y lo más importante — este documento no tiene campo guest en absoluto: en lugar de
    // un invitado hay una organización y una persona de contacto. La forma se diferencia
    // de las demás no en un campo, sino en esencia. Esto tendrá eco más adelante en la
    // lab: la regla de validación de documentos no podrá exigir guest a todos, de lo
    // contrario un pase de grupo legítimo no pasaría.
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

// countDocuments({}) — contar los documentos que cumplen una condición; una condición
// vacía significa «todos». La impresión hace falta para que el archivo tenga un resultado
// visible: insertMany mismo responde con una lista de identificadores emitidos, y en ella
// es fácil no ver cuántos documentos realmente se guardaron.
print("documentos en la colección: " + db.passes.countDocuments({}));
