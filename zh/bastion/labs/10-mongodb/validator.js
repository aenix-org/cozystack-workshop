// 实验 10 · passes 集合的文档校验规则（schema 校验器）。
//
// 这是一段用于 mongosh —— MongoDB 命令行 —— 的程序。它在虚拟机上、
// 在实验集群里，通过 README 中的短命令 `mo` 运行：
//     cd labs/10-mongodb && mo < validator.js
// 作为响应，你会看到一行「规则已安装」。
//
// 什么是校验 schema。默认情况下集合没有 schema：数据库接受
// 任意形状的文档，字段名里的拼写错误（把「type」写成「tipe」）也会被悄悄存下 ——
// 这样的疏漏门口的保安是发现不了的。校验器就是对文档
// 应当长成什么样的描述。从它被应用的那一刻起，数据库会自己检查每一次插入和每一次
// 修改。
//
// 不符合规则的文档会怎样：它不会被写入，
// 操作会返回错误 MongoServerError: Document failed validation。集合中
// 已经存在的文档，在安装规则时不会被检查、也不会被
// 重写 —— 但之后对它们的修改会开始被拒绝。因此垃圾数据
//（没有 type 字段的文档）要在应用本文件之前清理，而不是之后。

// runCommand —— 直接向数据库发送命令，绕过常用的 db.<集合>.<...>。
// collMod —— 「修改一个已存在集合的设置」。规则是事后挂到一个在线的
// 集合上的：无需停库、无需迁移数据。
db.runCommand({
  collMod: "passes",
  // validator —— 规则本身。$jsonSchema —— 描述文档形状的一种方式：
  // 哪些字段必填、它们是什么类型、允许哪些取值。
  validator: {
    $jsonSchema: {
      // 最顶层的文档本身 —— 是一个对象。
      bsonType: "object",
      // 缺了就不接受文档的那些字段。请注意列表里没有什么：
      // guest。团体通行证里代替客人的是单位，规则必须
      // 足够宽泛，好让文档的合法形态能从中
      // 通过。这个约束立刻就能感觉到：文档越是多样，
      // 能对所有文档统一要求的东西就越少。
      required: ["type", "host"],
      // 对单个字段的要求。没有在这里列出的字段完全不会被检查
      // —— 未知字段会照样进入文档。可以禁止这一点
      //（additionalProperties: false），但那样每加一个新字段都要改
      // 规则，于是你又回到了动辄就要迁移 schema 的境地。界线画在哪里 ——
      // 由你决定，而它永远是一种折衷。
      properties: {
        // 通行证类型 —— 只能是所列四个取值之一。第五种类型
        // 就需要修改这条规则，这是好事：改动会变成有意识的。
        type: {
          enum: ["一次性", "每周", "车辆", "团体"],
          description: "通行证类型，只能从列表中选取"
        },
        // 是哪位员工申请了通行证。该字段必填，且必须是
        // 字符串。
        host: {
          bsonType: "string",
          description: "由哪位员工下单"
        },
        // guest 在 properties 里，但不在 required 里：如果文档中有这个字段，
        // 它就必须是字符串；如果没有 —— 文档依然合法。
        guest: {
          bsonType: "string"
        },
        // 规则在嵌套对象内部也起作用。没有 car 字段 —— 就没有任何
        // 要求。有 —— 那它必须是对象，且其中的车牌号
        // 必填，而挂车（如果指定）—— 是布尔值，而不是字符串
        //「否」。
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
        // 应当长成什么样：name 必填，age —— 如果指定 —— 是整数。
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
  // strict —— 检查所有插入和所有修改。较宽松的 moderate 变体
  // 检查新文档以及对那些已符合规则的文档的修改，而把旧的
  // 参差不齐留着不动。正是用 moderate 才在一个已经积累了垃圾的集合上
  // 开启校验：先停止继续把它弄坏，再修
  // 旧的，然后切换到 strict。
  validationLevel: "strict",
  // error —— 拒绝不合适的文档。warn 变体会写入日志并仍然
  // 接受它：适合花一周时间看看都进来些什么，然后再开启
  // 拒绝、去弄坏某个人正在工作的代码。
  validationAction: "error"
});

// runCommand 会返回一个对象，其中成功看起来是 { ok: 1 }。我们打印
// 自己的一行，好让应用本文件的结果一眼就能读出来。
print("规则已安装");
