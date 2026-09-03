## 30. 第 9 步：验证整条链路

**见分晓的时刻**

⚠️ **先在虚拟机内部关掉 firewalld。** 迁移过来的 CentOS 把它上一段生命里的规则也一并带了过来，对外只放开 SSH。应用端口是关着的，从外面看就像「应用挂了」。

```bash
systemctl stop firewalld
systemctl disable firewalld
```

就在那里、从机器内部，确认应用是活的：

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` —— 应用有响应。`503` —— 回到网络那一步。这里的 `localhost` 就是你正待着的这台机器：应用在自己检查自己。

📍 **接下来 —— 从外部按域名做一次检查。** 这条路径不需要端口转发：讲师已经提前在你的租户里创建了一个 `Ingress`，只要机器内部的应用在 `8080` 上监听，商店就会发布在 `https://app.workshopXX.workshop.aenix.io`（`XX` 是你的编号）。在你笔记本的浏览器里打开它 —— 或者直接在 bastion 上用 `curl` 检查：

```bash
# 健康检查
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

# 创建一个订单
curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# 看看它是否被记录下来了
curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

⚠️ 只要 app-VM 还没起来或仍在启动，域名就会返回 `503` —— 这是正常的：`Ingress` 在等后端。一旦你看到 `200`，就说明里面的机器已经在 `8080` 上监听了。

如果订单创建成功 —— 你已经走完了整条路。应用从 VMware 迁了过来，运行在集群里，写入一个托管数据库，并把事件发送到一个托管队列。

半小时前，这套系统还活在 ESXi 上。
