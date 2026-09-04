-- 实验 9 · 通行日志表：每次刷闸机对应一行。
--
-- 在哪里运行：在笔记本上、在实验集群中，通过 README 里的简短命令 `ch`
-- 运行——它把 SQL 放在一个普通 POST 请求的正文里发送给 ClickHouse：
--     cd labs/09-clickhouse && ch < 01-schema.sql
-- CREATE TABLE 返回的响应为空——这就是成功的样子。
--
-- 这里没有 CREATE DATABASE，也没有 CREATE USER：数据库和用户是在下单时由
-- 服务本身建立的（仪表盘，或本文件夹里的 clickhouse.yaml 文件）。

-- IF NOT EXISTS——如果表已经存在就不报错。这个文件可以应用两次。
CREATE TABLE IF NOT EXISTS passes
(
    -- 通行证编号。UInt64 和 UInt16——分别为 8 字节和 2 字节的无符号整数。
    -- 在 ClickHouse 里类型的大小是有意选择的：在十亿行上，列里每多一个
    -- 字节就会变成磁盘上多一个 GB。
    pass_id      UInt64,
    -- 人经过闸机的时间。整个报表都是围绕这一列构建的。
    created_at   DateTime,
    -- 访客姓名。几乎每一行都各不相同，所以用普通的 String。
    guest_name   String,
    -- 下面三列是 LowCardinality(String)：一种取值很少的字符串
    --（部门有五个，入口有三个，通行证类型有四种）。ClickHouse
    -- 为这样的列保留一个字典，往磁盘上写编号，而不是把重复了
    -- 一百万次的词写下去。
    -- 规则：不同取值最多几千个——用 LowCardinality，更多就用
    -- 普通的 String。把 guest_name 这样包装反而比不包装更糟：
    -- 一百万个唯一姓名的字典会比数据本身还大。
    host_dept    LowCardinality(String),
    entrance     LowCardinality(String),
    pass_type    LowCardinality(String),
    -- 访客在里面待了多少分钟。两个字节绰绰有余。
    duration_min UInt16
)
-- 表引擎——即 ClickHouse 在磁盘上存储数据的方式。熟悉的数据库里没有
-- 这种选择；这里有，而且是在建表时做出的。
-- MergeTree：每次插入都在磁盘上放一个新的分块（part），分块在后台合并
-- 成更大的。因此有个实用规则——按多行成批插入。
-- 一百万次单行插入会创建一百万个分块，把服务器拖垮。
ENGINE = MergeTree
-- 文件里最重要的一行，而且要在任何数据进入表之前就选好。
-- ORDER BY 设定行在磁盘上物理排列的顺序，它同时充当唯一真正的索引：
-- ClickHouse 每隔几千行存一个标记（mark），并用它们来判断文件的
-- 哪些分块可以完全跳过不读。
--
-- 由此可见：「三月里有多少次通行」变成只读取文件的一段，
-- 而「找出编号为 424242 的通行证」则变成读取整个 pass_id 列，
-- 因为 pass_id 不在排序键里。这不是缺陷，而是设计使然。
--
-- 用熟悉的世界打比方：和纸质档案里做的决定一样——把通行证
-- 按日期或按姓氏排列。按日期排好后，三月那一册瞬间就能抽出，
-- 而要找某个 Иванов 就得逐份翻查。而且没人会事后去把
-- 一百万张纸重新排一遍。
--
-- 文件里故意没有 PARTITION BY。分区（partition）是一组独立的分块
--（通常按月），可以用一条命令丢弃；这对「只保留两年」这样的规则很方便。
-- 在八个月的教学数据上，分区只会白白增加分块而无益处，而在这里
-- 削减不必要的读取正是排序键所擅长的。
ORDER BY (created_at, entrance)
