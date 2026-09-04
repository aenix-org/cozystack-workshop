// 实验 10 · passes 集合的文档校验规则（模式校验器）。
//
// 一个供 mongosh —— MongoDB 命令行——运行的程序。在笔记本上、
// 在实验集群里，用 README 中的简短命令 `mo` 执行：
//     cd labs/10-mongodb && mo < validator.js
// 作为回应，你会看到这一行「правило установлено」。
//
// 什么是校验模式。默认情况下集合没有模式：数据库会接受
// 任意形状的文档，并把字段名里的拼写错误（「tipe」而不是「type」）悄无声息地存下来——
// 这样的疏漏，门口的保安是抓不到的。校验器就是对一个文档
// 应当是什么样子的描述。从它被应用的那一刻起，数据库就自己检查每一次插入和每一次
// 修改。
//
// 不符合规则的文档会怎样：它不会被写入，
// 操作会返回 MongoServerError: Document failed validation。已经
// 躺在集合里的文档，在应用规则时不会被检查、也不会被改写——
// 但对它们的后续修改会开始被拒绝。因此垃圾数据
//（没有 type 字段的文档）要在应用此文件之前清除，而不是之后。

// runCommand —— 直接向数据库发送命令，绕过惯常的 db.<集合>.<...>。
// collMod ——「修改一个已存在集合的设置」。规则是事后挂到一个运行中的
// 集合上的：无需停库、也无需迁移数据。
db.runCommand({
  collMod: "passes",
  // validator —— 规则本身。$jsonSchema —— 描述文档形状的一种方式：
  // 哪些字段是必需的、是什么类型、允许哪些取值。
  validator: {
    $jsonSchema: {
      // 顶层文档本身是一个对象。
      bsonType: "object",
      // 缺少了就不会被接受的字段。请注意列表里没有什么：
      // guest。团体通行证用的是组织而不是访客，规则必须
      // 足够宽泛，好让一份合法形状的文档能从中通过。
      // 这个约束会立刻被感受到：文档越是多样，
      // 就越是不能对所有文档同时提出要求。
      required: ["type", "host"],
      // 对单个字段的要求。这里没有列出的字段完全不会被检查
      //——一个未知字段会径直进入文档。你可以禁止这一点
      //（additionalProperties: false），但那样每一个新字段都会需要修改
      // 规则，于是你又回到了动辄迁移模式的状态。界线画在哪里——
      // 是你的决定，而且它永远是一种折衷。
      properties: {
        // 通行证类型——只能是所列四个取值之一。第五种类型
        // 将需要修改这条规则，这是好事：修改会变得是有意为之的。
        type: {
          enum: ["разовый", "недельный", "автомобильный", "групповой"],
          description: "тип пропуска, только из списка"
        },
        // 是哪位员工申领的通行证。这个字段是必需的，而且必须是
        // 字符串。
        host: {
          bsonType: "string",
          description: "кто из сотрудников заказал"
        },
        // guest 在 properties 里，但不在 required 里：如果文档中有这个字段，
        // 它就必须是字符串；如果没有——文档依然是合法的。
        guest: {
          bsonType: "string"
        },
        // 规则在嵌套对象内部同样有效。没有 car 字段——就没有任何
        // 要求。有的话——它必须是一个对象，其中的车牌号
        // 是必需的，而挂车（如果指定了）是一个布尔值，而不是字符串
        //「нет」。
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
        // 在列表内部也一样。items 描述参与者列表中每个元素
        // 应当是什么样子：name 是必需的，age——如果指定了——是整数。
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
  // strict —— 检查所有插入和所有修改。更宽松的 moderate 选项
  // 检查新文档以及对那些已经符合规则的文档的修改，而把旧的
  // 参差不齐的数据放在一边不管。正是用 moderate 来在一个已经
  // 积累了垃圾数据的集合上开启校验：先不再把它继续弄糟，再修
  // 旧数据，然后切换到 strict。
  validationLevel: "strict",
  // error —— 拒绝不合格的文档。warn 选项会写进日志但仍然
  // 接受：适合用一周时间观察进来的都是些什么，然后再打开
  // 拒绝、并弄坏某人正在运行的代码。
  validationAction: "error"
});

// runCommand 回应的是一个对象，其中成功看起来像 { ok: 1 }。我们打印
// 自己的一行，好让应用此文件的结果一眼就能读懂。
print("правило установлено");
