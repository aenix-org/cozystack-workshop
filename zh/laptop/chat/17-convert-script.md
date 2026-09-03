## 17. 深入解析：convert.sh 都做了什么

脚本一共五步，每一步都会打印出自己正在做什么。

**第 1 步 —— 检查硬件加速。** 它会查看是否存在 `/dev/kvm` 设备。`virt-v2v` 内部会启动一台很小的虚拟机来进到镜像里面 —— 如果处理器被透传进我们这台机器，这种嵌套虚拟化就跑得很快。如果没有，就会切换到软件模式：慢一些，但能用。`LIBGUESTFS_BACKEND=direct` 这一行正是切换到这种模式的开关。

**第 2 步 —— 下载源镜像。**

```bash
wget -O source.ova "$OVA_URL"
```

它会从工作坊的共享存储 —— 也就是上面那张图里的那个 —— 拉取 `app-1.ova`。讲师事先把文件上传到了那里。**在你自己的项目里，这个位置对应的就是从 vSphere 导出：** `Export OVF Template` 或者 `ovftool`，然后是同样的重新打包。

**第 3 步 —— 重新打包本身。**

```bash
virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app
```

`-i ova` —— 输入是什么：一个 OVA 格式的文件。`-o local -os /root/out` —— 把结果放到哪里：放进本地文件夹 `/root/out`。`-of qcow2` —— 一个**必需**的标志：没有它 `virt-v2v` 就会挑一个默认格式，而平台不会接受那样的磁盘。`-on app` —— 给结果起什么名字，文件名 `app.qcow2` 就是从这里来的。

这会花上几分钟 —— 屏幕上会滚过 `Copying disk 1/1` 之类的行。上面提到的那第二项、看不见的驱动处理工作，正是在这里发生的。

**第 4 步 —— 上传到你的 Bucket。**

```bash
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app.qcow2 "mybucket/$BUCKET/app.qcow2"
```

`mc alias set` 会把存储地址和密钥记在一个短名字 `mybucket` 下面，这样后面就不用在每条命令里重复它们了。`mc cp` 复制文件 —— 语法有意做得和普通的 `cp` 一样。

**第 5 步 —— 给平台的一个链接。**

```bash
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"
```

它会创建一个有效期七天（168 小时）的临时签名链接。所谓「签名」 —— 就是说地址里嵌入了一段加密签名，凭这个链接谁都能下载文件，但只能凭它、而且只能在它还有效的时候。既不需要把 Bucket 向全世界开放，也不需要把访问密钥交给平台。

链接就在输出里 `Share:` 这个词后面找 —— 下一个阶段会用到它。
