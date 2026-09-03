## 31. 当某些东西不工作时

**大家常踩的坑，简短列一下**

• **应用从外部访问不到。** 在迁移过来的 CentOS 上，通常的元凶是内置防火墙——它挡住了 8080 端口：
  ```bash
  systemctl stop firewalld
  ```

• **`kubectl` 回答「forbidden」。** 检查一下你访问的是不是自己的 namespace：
  `-n tenant-workshopXX`。另外记住，可用的是 `vminstance`，而不是 `vm` 或 `vmi`。

• **订单创建不了，但健康检查却返回 `200`。** 是那张表没有创建——回到那条关于数据库 schema 的消息。

• **新机器（app-VM）卡在 `Pending`。** 转换机没有关掉——它占着 8Gi 的配额，剩下的不够给新机器。把它和它的磁盘删掉：
  ```bash
  kubectl delete vminstance convert --namespace tenant-workshopXX
  kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
  ```

• **上传镜像时 `mc` 报 `Insufficient permissions`。** 在 `convert.sh` 里，`BUCKET` 字段填的是 `my-images`，而不是真正的 `bucketName`（那个长长的 `bucket-...-...`）。从控制台里 bucket 的 secret 中取出 `bucketName`，把它填进去。

• **磁盘卡在 Terminating 状态。** 多半是磁盘大小小于镜像。对于 ubuntu-20.04，至少需要 25Gi。

• **怎么都不行。** 在这里留言，我们一起来排查。这是工作中很正常的一部分，不必觉得尴尬——真实的迁移也一样，只不过是在凌晨三点。
