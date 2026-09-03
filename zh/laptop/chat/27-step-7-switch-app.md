## 27. 第 7 步：把应用切换到托管服务

**把写死的地址换成名称**

📍 **位置：** 在你自己的虚拟机里，重启之后。

📄 这是 `scripts/connect-managed.sh` 的内容。同样请手动敲一遍——原因相同，而且总共只有三条命令。

在机器内部，打开应用的配置文件：
```bash
cat /etc/orders/application.properties
```
你会看到那两个熟悉的 `192.168.10.30` 和 `192.168.10.40`。这就是每一个遗留系统的痛点：已经没人记得当初为什么偏偏是这两个地址。

把它们替换成服务名称（用你自己的编号替换 `XX`）：
```bash
sed -i 's|192.168.10.30|postgres-db-rw.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
sed -i 's|192.168.10.40|kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
systemctl restart orders-api
```
（用两条命令，而不是一条带换行的命令：从聊天里复制时换行常常会丢失，命令就只执行了一半）

验证一下：
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```
`200`——应用既能看到数据库，也能看到队列。如果得到 `503`，请回到网络那一步，多半是地址没有改成功。
