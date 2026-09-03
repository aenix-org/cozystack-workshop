## 29. 第 8 步：安装客户端并应用 schema

**数据库访问信息：**
```
host:     postgres-db-rw.tenant-workshopXX.svc.cozy.local
database: orders
login:    orders
password: Orders2019!
```
密码在 `manifests/04-managed.yaml` 中设置，不用再去别处找。

⚠️ **CentOS 7 自带的 psql 不行。** 它是 9.2 版本，而我们的数据库要求 SCRAM 认证，它处理不了，
于是会回复：`psql: SCRAM authentication requires libpq version 10 or above`。你需要 10 或更新版本的客户端。
我们从 PGDG 仓库里取——对 CentOS 7 来说，那里能拿到的最新版本是 15。

连着三条命令，每条都有各自的一个理由：

```bash
# 1. 接入 PGDG 仓库——PostgreSQL 软件包的来源。
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd 库，没有它客户端装不上。CentOS 7 的仓库里没有它，
#    所以我们从 EPEL 归档里取。
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. 客户端本身——只从仍然可用的 pgdg15 仓库取。
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

第二条和第三条命令看起来多余，但没有它们安装就会失败，否则这两个错误你都会亲眼看到：

- 没有 `libzstd`——`Requires: libzstd >= 1.4.0`；
- 没有 `--disablerepo`/`--enablerepo`——`HTTPS Error 410 - Gone`。这个仓库包会一次性
  拉进所有 PostgreSQL 版本，包括已经停止支持的 12 和 13，而 `yum` 在安装前会遍历**每一个**
  已启用的仓库，并在第一个失效的仓库上失败。我们显式地只保留自己需要的那一个。

检查客户端是否就位：

```bash
psql --version
```

如果回复是 `command not found`，说明客户端装到了 `PATH` 之外；找到它，并为当前会话把它
所在的目录加进去：

```bash
ls /usr/pgsql-*/bin/psql
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**取回 schema 文件**——这台机器已经有网络了：

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql
```

**应用它。** 我们把这条命令逐段拆开，好让你不至于盲敲：

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -f orders-schema.sql
```

- `PGPASSWORD='...'`——密码通过环境变量传入，这样 `psql` 就不会以交互方式来询问它。
  脚本里就是这么做的。
- `-h postgres-db-rw.tenant-workshopXX.svc.cozy.local`——数据库地址。这**不是 IP**，
  而是集群内部的一个名字。`-rw` 后缀很关键：托管 Postgres 有多个副本，而这个名字始终指向
  你**可以写入**的那一个。还有一个配对的带 `-ro` 的名字——只读。当角色在副本之间切换时，
  名字不变，正因如此，应用的配置里写的是这个名字，而不是某台具体服务器的地址。
- `-U orders`——以哪个用户身份连接，`-d orders`——连接到哪个数据库。
- `-f orders-schema.sql`——执行文件里的命令。

正是这种通过一个固定名字、而非通过 IP 来访问数据库的能力，才让副本切换对应用来说不可见。
在旧机器上，你配置里写的是 `localhost`，那时候根本就不存在什么切换。

检查表是否就位：

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -c '\dt'
```

出现了——就说明订单现在能创建了。我们会在下一步连同整条链路一起验证这一点。
