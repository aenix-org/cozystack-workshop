## 28. 第 8 步：为什么应用仍然失败

**数据库是空的——应用需要它的 schema**

📍 **位置：** 在你自己的机器里——也就是你在第三阶段启动的那台（app-VM）。不是在 bastion 上。它已经在集群网络里，可以按名字看到数据库。

### 首先——再做一次检查，它同样不会通过

我们把地址改好了，应用重启了，它的健康检查端点返回 `200`。看起来一切就绪。我们来试着创建一个订单：

```bash
curl -s -X POST localhost:8080/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"item":"test order"}' -w '\nHTTP %{http_code}\n'
```

**返回的是 `500`。** 尽管刚才健康检查还是 `200`。

<details>
<summary><b>答案，以及一个比这个错误更宽泛的教训</b></summary>

因为这个应用的健康检查只看**是否连上了**数据库：连接打开了，服务器应答了——于是就算「活着」。它需要的那些表在不在里面，它并不检查。

而表根本不存在。当你从目录里订购 Postgres 时，拿到的是一台**空服务器**：`orders` 数据库和 `orders` 用户已经建好，仅此而已。在旧机器上表是存在的——它们是应用很久以前第一次启动时创建的，这么多年过去，所有人都把这事忘了。

顺带地，你刚刚也看清了一个绿色的健康检查到底值多少。它说的是「我连通了数据库」，而不是「我在正常工作」。在真实项目里，很容易在这样一个检查之上搭起监控，它会欢快地把一切显示成绿色，而与此同时用户连一个订单都下不了。

</details>

**我们要做什么。** 我们搬的是应用，不是它的数据，所以这些表得重新创建。这件事只做一次，用一个包含一串 SQL 命令的文件来完成。这样的文件被称为 **schema**——它描述存储是怎么组织的：有哪些表、表里有哪些字段、字段是什么类型。

<details>
<summary><b>细看一下：orders-schema.sql 里面有什么</b></summary>

这个文件是仓库里的 `scripts/orders-schema.sql`。里面只有两条命令。

**第一条创建订单表：**

```sql
CREATE TABLE IF NOT EXISTS orders (
    id           BIGSERIAL PRIMARY KEY,
    item         TEXT        NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'NEW',
    created_by   TEXT,
    processed_by TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);
```

逐个字段来看：

- `id BIGSERIAL PRIMARY KEY` — 订单号。`BIGSERIAL` 意思是「由数据库自己按顺序发下一个」，`PRIMARY KEY` 意思是「它是唯一的，用它来查这一行」。
- `item` — 订购了什么。`NOT NULL` — 没有物品的订单毫无意义，数据库不会接受这样一行。
- `status` — 订单的状态，默认为 `NEW`。当消息经过 Kafka 后，它会变成 `PROCESSED`。
- `created_by` / `processed_by` — 谁创建的、谁处理的。应用正是往这里写入 `kafka`，也正是靠这个字段，在第 9 步能看出队列确实在工作。
- `created_at` / `processed_at` — 什么时候。`TIMESTAMPTZ` — 带时区的时间戳。
- `IF NOT EXISTS` — 「如果表已经存在，就什么都不做、也别报错」。有了这个，文件可以重复应用而不会破坏任何东西。

**第二条添加一行历史记录：**

```sql
INSERT INTO orders (...) SELECT '12x rack rails', 'PROCESSED', ...
WHERE NOT EXISTS (SELECT 1 FROM orders);
```

这纯属点缀：为的是在第 9 步订单列表不是空的。`WHERE NOT EXISTS` 意思是「只在表为空时才插入」——再运行一次也不会产生重复行。

**文件里被刻意省掉的东西：** 既没有 `CREATE DATABASE`，也没有 `CREATE USER`。数据库和角色都已经在你第 5 步订购 Postgres 时由 Cozystack 目录创建好了。这正是托管服务的意义所在：它把这些例行杂事揽在自己身上，剩下留给你的只有你自己的 schema。

</details>

> ⚠️ **文件注释里的不一致。** `orders-schema.sql` 的文件头里说，首先需要以超级用户身份执行 `GRANT CREATE,USAGE ON SCHEMA public`。**这已经过时了，不要做**——`orders` 角色属于 `orders_admin`，后者拥有该数据库和 schema，所以它已经具备这些权限。已验证。我们会把文件里的注释改正过来。
