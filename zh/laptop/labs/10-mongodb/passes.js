// 实验 10 · passes 集合中四种不同形态的四张通行证。
//
// 这不是一个配置文件，而是一段供 mongosh 运行的程序——mongosh 是 MongoDB 的
// 命令行界面，它能理解 JavaScript。它在你的笔记本上、在实验集群里运行，用 README
// 里那条简短的 `mo` 命令启动（它会在工作 Pod 内部启动 mongosh）：
//     cd labs/10-mongodb && mo < passes.js
// 作为回应，你会看到这样一行「集合中的文档数: 4」。
//
// 把这个文件运行两次，文档就会变成八个：insertMany 只会追加。

// db 是你所连接的数据库；passes 是其中的一个集合（最接近表的类比物）；insertMany
// 意为「把这些文档加进来」。你无需事先创建任何表，也没有地方去描述字段：集合会在
// 第一次插入的那一刻出现，而数据库默认对文档可以有哪些字段并无成见。
// 正因如此，下面四个文档拥有不同的字段集合，却仍然并排躺在同一个集合里。文档模型
// 存在的意义正在于此：没有空列，没有为四种通行证准备的四张表，也没有第五张把它们
// 关联起来的表。
db.passes.insertMany([
  {
    // 一次性通行证——最短的形态：六个字段，全是简单值。
    // 在普通的表里，这就是普通的一行。
    // ISODate(...) 不是字符串，而正是一个日期。MongoDB 以二进制的 BSON 格式存储
    // 文档，其中每个值都有类型：日期、整数、浮点数、布尔值。
    // 日期可以比较和排序，而字符串「2026-09-01」只有在书写格式恰好合适时才行。
    type: "一次性",
    guest: "王建国",
    host: "petrov@corp.example",
    entrance: "北门",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "面试"
  },
  {
    // 周通行证。这里不用 valid_on，而是用 valid_from 和 valid_to 这一对；不用单个
    // 入口，而是把入口列表 entrances 直接放在字段里。在表里，这样一个列表要么需要
    // 一张单独的「通行证—入口」表，要么需要一个逗号分隔的字符串，而后者之后就无法
    // 正常检索了。
    // 出现了一个 badge_returned 字段，它在一次性通行证里根本不存在：不是 NULL，也
    // 不是空，而正是那个文档里没有这个字段。这是两回事，检索它们的方式也不一样。
    type: "每周",
    guest: "林晓梅",
    host: "petrov@corp.example",
    entrances: ["北门", "南门"],
    valid_from: ISODate("2026-09-01T00:00:00Z"),
    valid_to: ISODate("2026-09-07T23:59:59Z"),
    purpose: "外部审计",
    badge_returned: false
  },
  {
    // 车辆通行证。所有与车有关的东西都放在 car 这一个字段里面。这不是一个内部塞了
    // JSON 的字符串，而是一个完整的嵌套结构：你可以按 car.plate 检索并为它建立索引。
    type: "车辆",
    guest: "陈志强",
    host: "logistics@corp.example",
    entrance: "西门",
    valid_on: ISODate("2026-09-02T07:30:00Z"),
    car: {
      plate: "京A12345",
      model: "福特全顺",
      trailer: false,
      weight_kg: 3500
    },
    parking: "P2"
  },
  {
    // 团体通行证。这里是一个对象列表：每个成员都有各自的字段，列表长度任意。
    // 而最重要的是——这个文档根本没有 guest 字段：代替客人的是一个组织和一位联系
    // 人。它的形态与其他文档的差别不在于某一个字段，而在于本质。这一点在实验后面
    // 会有回响：文档校验规则将无法要求所有文档都有 guest，否则一张合法的团体通行证
    // 就无法通过。
    type: "团体",
    organization: "市第一中学",
    contact: "赵丽娟",
    host: "hr@corp.example",
    entrance: "北门",
    valid_on: ISODate("2026-09-03T10:00:00Z"),
    escort: "刘伟明",
    members: [
      { name: "孙鹏", age: 16 },
      { name: "周敏", age: 15 },
      { name: "吴浩", age: 17 }
    ]
  }
]);

// countDocuments({}) — 统计符合条件的文档；空条件意味着「全部」。之所以需要打印，
// 是为了让文件有一个可见的结果：insertMany 本身回应的是一串已发放的标识符列表，在
// 其中很容易看不清实际到底落入了多少个文档。
print("集合中的文档数: " + db.passes.countDocuments({}));
