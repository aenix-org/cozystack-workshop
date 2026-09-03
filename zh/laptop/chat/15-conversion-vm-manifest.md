## 15. 细看：02-conversion-vm.yaml 里有什么

这个文件里有**两个**对象，用一行 `---` 分隔。YAML 就是这样把多个文档打包进一个文件的。虚拟机离不开磁盘，所以磁盘要单独描述，而且总是最先创建。

```yaml
kind: VMDisk
metadata:
  name: convert-tools
spec:
  source:
    image:
      name: ubuntu-20.04
  storage: 25Gi
  storageClass: replicated
```

`kind: VMDisk` —— 磁盘本身就是一个独立的对象。这需要一点适应：在 vSphere 里磁盘是机器的一个属性，而这里它是一个独立的实体，你可以提前创建它，挂载到一台机器上，再卸下来挂到另一台机器上。

`source.image.name: ubuntu-20.04` —— 内容从哪里来。这就是上面那张图里的那个镜像目录：Cozystack 已经预先从 `cloud-images.ubuntu.com` 下载了官方的 Ubuntu 20.04 云镜像，并保存在本地。这里我们请求它据此做一份拷贝。没人会为此去访问互联网，拷贝是在集群内部完成的。

⚠️ **Ubuntu 版本是特意指定的，不要改动它。** 在 24.04 上机器无法启动；在 22.04 上，重新打包会卡在 CentOS 7 内部那套旧的 RPM 软件包数据库上 —— `virt-v2v` 无法解析它。这些都已经替你验证过了。

`storage: 25Gi` —— 磁盘大小。目录里的 Ubuntu 镜像占 20Gi，而**磁盘必须比镜像大**，否则拷贝会在中途中断，磁盘随后会卡在 `Terminating` 状态里碍事。留出余量还有一个原因：下载下来的 `app-1.ova` 和重新打包的结果会同时放在磁盘里。

`storageClass: replicated` —— 怎么存。`replicated` 表示在不同节点上存多份副本：某个节点宕机了 —— 数据还在。它对应 vSphere 里的存储策略。另外还有 `local` —— 更快，但只存在于单个节点上。

```yaml
kind: VMInstance
metadata:
  name: convert
spec:
  instanceType: u1.large
  instanceProfile: ubuntu
  runStrategy: Always
  disks:
    - name: convert-tools
```

`instanceType: u1.large` —— 机器的规格，一个现成的组合，「多少个 CPU、多少内存」：这里是两个 CPU 和八个 GB。重新打包会把镜像分块保存在内存里，对内存的消耗是实打实的。

`instanceProfile: ubuntu` —— 一组针对这个客户机系统定制的虚拟硬件设置：用哪些磁盘控制器、哪块网卡、时钟怎么透传。最接近的对应物是创建 VM 向导里的「Guest OS Type」，它同样会为了适配所选系统而悄悄改动十来项设置。

`runStrategy: Always` —— 让机器保持运行，如果它崩溃了就把它重新拉起来。这不是「主机开机时自动启动」，而是一条长期生效的规则：平台会确保机器处于运行状态。

`disks` —— 要挂载哪些磁盘。按名字引用上面描述的那个 `VMDisk` 对象。

```yaml
  cloudInit: |
    #cloud-config
    password: ubuntu
    packages: [ libguestfs-tools, virt-v2v, qemu-utils ]
    runcmd:
      - [ bash, -c, "wget ... mc && chmod +x /usr/local/bin/mc" ]
```

`cloudInit` —— 机器在首次启动时自己执行的一组指令。这是所有云镜像的标准机制：系统启动时会查找这样一段文本并执行它。在 vSphere 里最接近的对应物是 Customization Specification，只不过这里它是以文本形式描述的，并且和机器本身放在同一个文件里。

这里我们请求它设置一个密码，安装 `virt-v2v` 及其依赖，并下载 `mc` —— 一个用于操作 S3 存储的命令行客户端，正是我们稍后要用来把结果上传到 bucket 里的那个。

⚠️ **明文密码** —— 只适用于培训测试环境：这台机器只存活半小时，而且只能从集群内部访问。在真实机器上，你应该用 ssh 密钥来代替 `password`。
