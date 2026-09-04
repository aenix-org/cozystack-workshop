// Lab 10 · una regla de validación de documentos (validador de esquema) para la colección passes.
//
// Un programa para mongosh — la shell de MongoDB. Se ejecuta en la máquina virtual,
// en el clúster de laboratorio, con el comando corto `mo` del README:
//     cd labs/10-mongodb && mo < validator.js
// En respuesta verás la línea «правило установлено».
//
// Qué es un esquema de validación. Por defecto una colección no tiene esquema: la base acepta
// un documento de cualquier forma y guarda en silencio una errata en el nombre de un campo («tipe» en vez de «type») —
// un descuido que el guardia en el control de acceso no detectará. Un validador es una descripción de cómo
// debe verse un documento. Desde el momento en que se aplica, la base comprueba cada inserción y cada
// modificación por sí misma.
//
// Qué le ocurre a un documento que no cumple la regla: no se escribe,
// y la operación devuelve un error MongoServerError: Document failed validation. Los documentos
// que ya están en la colección no se comprueban ni se
// reescriben al instalar la regla — pero su edición posterior empezará a ser rechazada. Por eso la basura
// (documentos sin el campo type) se elimina antes de aplicar este archivo, no después.

// runCommand — enviar un comando a la base directamente, sin pasar por el habitual db.<colección>.<...>.
// collMod — «cambia los ajustes de una colección existente». La regla se acopla a una colección
// viva a posteriori: no hace falta detener la base ni recargar los datos.
db.runCommand({
  collMod: "passes",
  // validator — la regla en sí. $jsonSchema — una forma de describir la forma de un documento:
  // qué campos son obligatorios, de qué tipo son y qué valores se permiten.
  validator: {
    $jsonSchema: {
      // El propio documento de nivel superior — un objeto.
      bsonType: "object",
      // Los campos sin los cuales un documento no se acepta. Fíjate en lo que NO está en la lista:
      // guest. Un pase de grupo tiene una organización en lugar de un invitado, y la regla debe
      // ser lo bastante amplia para que la forma legítima del documento
      // pase por ella. La restricción se nota enseguida: cuanto más variados son los documentos,
      // menos se puede exigir a todos a la vez.
      required: ["type", "host"],
      // Requisitos para campos individuales. Un campo que no figura aquí no se comprueba
      // de ninguna manera — un campo desconocido pasará al documento. Esto se puede prohibir
      // (additionalProperties: false), pero entonces cada campo nuevo exigirá editar
      // la regla, y volverás a una migración de esquema por cualquier nimiedad. Dónde trazar la línea —
      // es tu decisión, y siempre es un compromiso.
      properties: {
        // El tipo de pase — solo uno de los cuatro valores enumerados. Un quinto tipo
        // exigirá cambiar esta regla, y eso es bueno: el cambio se volverá deliberado.
        type: {
          enum: ["разовый", "недельный", "автомобильный", "групповой"],
          description: "тип пропуска, только из списка"
        },
        // Qué empleado pidió el pase. El campo es obligatorio, y debe ser
        // una cadena.
        host: {
          bsonType: "string",
          description: "кто из сотрудников заказал"
        },
        // guest está en properties, pero no en required: si el campo está presente en el documento,
        // debe ser una cadena; si está ausente — el documento sigue siendo válido.
        guest: {
          bsonType: "string"
        },
        // Las reglas también funcionan dentro de objetos anidados. No hay campo car — ningún
        // requisito. Si lo hay — debe ser un objeto, y la matrícula del coche en él
        // es obligatoria, mientras que el remolque, si se indica, — es un valor booleano, no la cadena
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
  // strict — comprobar todas las inserciones y todas las modificaciones. La variante más blanda moderate
  // comprueba los documentos nuevos y las ediciones de aquellos que ya cumplen la regla, y deja el viejo
  // batiburrillo en paz. Es precisamente con moderate como se activa la validación en una colección
  // en la que ya se ha acumulado basura: primero se deja de empeorar, luego se arregla
  // lo viejo, luego se pasa a strict.
  validationLevel: "strict",
  // error — rechazar un documento inadecuado. La variante warn escribe en el registro y aun así
  // lo acepta: sirve para pasar una semana observando qué llega, antes de activar
  // el rechazo y romper el código que le funciona a alguien.
  validationAction: "error"
});

// runCommand responde con un objeto en el que el éxito se ve como { ok: 1 }. Imprimimos
// nuestra propia línea para que el resultado de aplicar el archivo se lea de un vistazo.
print("правило установлено");
