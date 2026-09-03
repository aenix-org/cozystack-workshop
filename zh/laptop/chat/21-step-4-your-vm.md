## 21. 第 4 步：你的虚拟机

**从你自己的镜像启动一台机器**

📍 **位置：** 在你的笔记本电脑上。

⚠️ **先关掉那台转换用的机器** —— 它已经完成了任务，还占着你 8Gi 的配额。
如果不清掉它，新机器就会卡在 `Pending`，看上去就像
测试环境坏了一样。在以往的工作坊中，几乎所有人都卡在这里：

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

镜像仍然留在 bucket 里 —— 我们正是要从它启动机器。

现在打开 `manifests/03-app-vm.yaml`，把预签名链接粘贴到 `url` 字段
并应用它：

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

集群会先从链接下载镜像，并把它分布到各个副本上 —— 这需要一两分钟。
然后机器就会启动。

进入机器：
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

**登录你的机器：**
```
login:    root
password: cozydemo
```

退出控制台 —— `Ctrl+]`。

**这里和转换用的机器一样，是同一对对象**，只是磁盘不是
从目录里取的，而是从你的链接下载的：

• **VM Disk** `app-1` —— 10Gi，source = http，就是那个预签名 URL
• **VM Instance** `app-1` —— 配置文件 `centos.7`，instance type `u1.medium`

名字相同，这没问题：磁盘和机器是不同类型的对象。在 `virtctl`
命令里，机器和上次一样，要带前缀来引用：**`vm-instance-app-1`**。

🖱 **通过控制台（dashboard）：** **1)** **VM Disk → Deploy new**：名字 `app-1`，source = **http**，
在 URL 字段填预签名链接，大小 `10Gi`，storage class `replicated`。
**2)** **VM Instance → Deploy new**：名字 `app-1`，instance type `u1.medium`，
profile `centos.7`，磁盘选 `app-1`。控制台 —— 机器页面上的 **VNC** 按钮。

注意你刚才做的事情：你用文本描述了一台虚拟机，
再用一条命令把它应用出来。你可以把这个文件放进代码仓库，
不点一次鼠标就启动一百台一模一样的机器。
