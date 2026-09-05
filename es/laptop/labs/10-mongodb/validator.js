// Lab 10 · regla de validación de documentos (validador de esquema) para la colección passes.
//
// Un programa para mongosh — el shell de MongoDB. Se ejecuta en el portátil,
// en el clúster de laboratorio, con el comando corto `mo` del README:
//     cd labs/10-mongodb && mo < validator.js
// En respuesta verás la línea «regla instalada».
//
// Qué es un esquema de validación. Por defecto una colección no tiene esquema: la base de datos acepta
// un documento de cualquier forma y guarda en silencio una errata en el nombre de un campo («tipe» en vez de «type») —
// esa omisión el guardia de la entrada no la detectará. Un validador es una descripción de cómo
// debe ser un documento. Desde el momento en que se aplica, la base de datos comprueba ella misma cada inserción y cada
// cambio.
//
// Qué le ocurre a un documento que no cumple la regla: no se escribirá,
// y la operación devuelve un MongoServerError: Document failed validation. Los documentos
// que ya están en la colección no se comprueban ni se reescriben cuando se aplica la regla —
// pero las ediciones posteriores sobre ellos empezarán a rechazarse. Por eso la basura
// (documentos sin el campo type) se elimina antes de aplicar este archivo, no después.

// runCommand — enviar un comando a la base de datos directamente, saltándose el habitual db.<colección>.<...>.
// collMod — «cambia la configuración de una colección existente». La regla se acopla a una colección
// viva a posteriori: no hace falta detener la base de datos ni migrar los datos.
db.runCommand({
  collMod: "passes",
  // validator — la regla en sí. $jsonSchema — una forma de describir la forma de un documento:
  // qué campos son obligatorios, de qué tipo y qué valores se permiten.
  validator: {
    $jsonSchema: {
      // El propio documento de nivel superior es un objeto.
      bsonType: "object",
      // Campos sin los cuales el documento no se aceptará. Fíjate en lo que NO está en la lista:
      // guest. Un pase de grupo tiene una organización en lugar de un invitado, y la regla debe
      // ser lo bastante amplia como para que una forma de documento legítima pase a través de ella.
      // La restricción se nota de inmediato: cuanto más variados son los documentos,
      // menos se puede exigir a todos ellos a la vez.
      required: ["type", "host"],
      // Requisitos para campos individuales. Un campo que no figure aquí no se comprueba
      // en absoluto — un campo desconocido pasará al documento. Puedes prohibir esto
      // (additionalProperties: false), pero entonces cada nuevo campo requerirá editar
      // la regla, y volverás a migrar el esquema a cada estornudo. Dónde trazar la línea —
      // es tu decisión, y siempre es un compromiso.
      properties: {
        // El tipo de pase — solo uno de los cuatro valores enumerados. Un quinto tipo
        // requerirá cambiar esta regla, y eso es bueno: el cambio se vuelve deliberado.
        type: {
          enum: ["puntual", "semanal", "vehicular", "grupal"],
          description: "tipo de pase, solo de la lista permitida"
        },
        // Qué empleado pidió el pase. El campo es obligatorio, y debe ser
        // una cadena.
        host: {
          bsonType: "string",
          description: "qué empleado hizo el pedido"
        },
        // guest está en properties pero no en required: si el campo está presente en el documento,
        // debe ser una cadena; si está ausente — el documento sigue siendo válido.
        guest: {
          bsonType: "string"
        },
        // Las reglas también funcionan dentro de objetos anidados. No hay campo car — sin
        // requisitos. Si lo hay — debe ser un objeto, y la matrícula del coche en él
        // es obligatoria, mientras que el remolque, si se indica, es un valor booleano, no la cadena
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
        // Y dentro de listas. items describe cómo debe ser cada elemento de la
        // lista de participantes: name es obligatorio, age — si se indica — un número entero.
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
  // strict — comprobar todas las inserciones y todos los cambios. La opción más suave moderate
  // comprueba los documentos nuevos y las ediciones de los que ya cumplen la regla, y deja en paz
  // el revoltijo antiguo. Es precisamente con moderate como se activa la validación en una colección
  // que ya ha acumulado basura: primero dejamos de empeorarla, luego arreglamos
  // lo antiguo, luego pasamos a strict.
  validationLevel: "strict",
  // error — rechazar un documento no adecuado. La opción warn lo registra y aun así
  // lo acepta: sirve para observar durante una semana qué llega, antes de activar
  // el rechazo y romper el código en funcionamiento de alguien.
  validationAction: "error"
});

// runCommand responde con un objeto en el que el éxito tiene el aspecto de { ok: 1 }. Imprimimos
// nuestra propia línea para que el resultado de aplicar el archivo se lea de un vistazo.
print("regla instalada");
