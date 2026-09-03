## 30. 第 9 步：验证整条链路

**见分晓的时刻**

⚠️ **先在虚拟机内部关掉 firewalld。** 迁移过来的 CentOS 把它上一段生命里的规则也一并带了过来，对外只放开 SSH。应用端口是关着的，从你笔记本做端口转发会撞上 `no route to host` —— 而这看上去就像「应用挂了」。

```bash
systemctl stop firewalld
systemctl disable firewalld
```

就在那里、从机器内部，确认应用是活的：

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` —— 可以做端口转发了。`503` —— 回到网络那一步。

📍 **接下来 —— 在你的笔记本上。** 把应用端口转发到自己这里：
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```
不要关掉运行这条命令的窗口：隧道只在它持续运行时才存在。

⚠️ **这里 `vmi/` 是必需的，而在 `virtctl console` 里正相反 —— 它反而碍事。** 这不是笔误，也不是我们的随性：这两条命令的目标写法不一样。`port-forward` 要求 `类型/名称`，缺了前缀就会回答 `target must contain type and name separated by '/'`。`console` 期望只给名称，带了前缀就会回答 `forbidden`，因为它把 `vmi` 这个词当成了机器的名字。

如果 virtctl 抱怨客户端和集群之间版本不一致 —— 那是一个警告，不是错误，也不碍事。

如果端口转发还是起不来，同样的隧道也可以通过机器的 Pod 来打通：
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <pod-name-from-output> 8080:8080
```

在另一个终端窗口里：
```bash
# 健康检查
curl -s http://localhost:8080/actuator/health

# 创建一个订单
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# 看看它是否被记录下来了
curl -s http://localhost:8080/api/orders
```

如果订单创建成功 —— 你已经走完了整条路。应用从 VMware 迁了过来，运行在集群里，写入一个托管数据库，并把事件发送到一个托管队列。

半小时前，这套系统还活在 ESXi 上。
