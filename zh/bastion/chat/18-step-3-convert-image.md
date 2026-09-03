## 18. 步骤 3：转换镜像

**把 VMware 镜像转换成 KVM 镜像**

📍 **位置：** 在你刚刚通过控制台登录进去的转换机里。不是在 bastion 上。

📄 我们要用的是 `scripts/convert.sh`。这台机器能联网，所以它会自己下载文件——不用再通过剪贴板复制任何东西。

直接把脚本从 GitHub 拉到机器上：
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/convert.sh
```

打开它：
```bash
nano convert.sh
```

**你在步骤 1 记下的那三个值，现在派上用场了。** 文件靠前的位置有一个标着「ВСТАВЬТЕ СВОИ ЗНАЧЕНИЯ」的代码块——把里面的占位符换成你自己的，引号保留原样：

```
BUCKET="your-bucket-name"
ACCESS_KEY="your-accessKey"
SECRET_KEY="your-secretKey"
```

`S3_ENDPOINT` 这一行和指向源镜像的链接不要动——它们已经是对的，而且对所有人都一样。

在 nano 里保存：`Ctrl+O`，然后 `Enter`，再按 `Ctrl+X` 退出。检查一下没有占位符残留：
```bash
grep ВСТАВЬТЕ convert.sh || echo "全部填好了，可以运行了"
```

运行它——一定要通过 `sudo`，脚本需要 root 权限。而且要**在 `screen` 里**运行：转换大约要五分钟，而你现在是挂在一条由两段连接组成的链路上（你的笔记本 → SSH 到 bastion → 转换机的控制台）。这条链路里任何一环断掉，普通的运行就会在中途中断。`screen` 能让进程一直活着，即使连接断了：

```bash
screen -S convert          # 开一个独立的会话
sudo bash convert.sh       # 在它里面运行
#  连接断了？重新登录到这同一台机器，然后：  screen -r convert
```

内部发生的事：脚本会下载源镜像，运行 `virt-v2v`，压缩结果，再把它上传到你的 bucket。

最重要的工作由 `virt-v2v` 完成。它改的不只是文件格式：它会把 virtio 驱动塞进客户机系统里，并修正引导程序。没有这一步，这台机器在新的虚拟机监控程序（hypervisor）上根本起不来。

⏳ **这大约要五分钟。** 我们的测试环境没有嵌套虚拟化，所以转换是在模拟模式下进行的。进度在控制台里可以看到——不要关掉它。

最后脚本会打印出一个指向你镜像的 **预签名链接**——在输出里找以 `Share:` 这个词开头的那一行，链接就紧跟在它后面。

**拿它做什么：** 把它复制到那同一个记事本里。下一步你会回到 bastion，打开 `manifests/03-app-vm.yaml`，把它粘贴到 `url` 字段里——就是现在放着 `ВСТАВЬТЕ_PRESIGNED_URL` 占位符的地方。就是我们填号码的时候我提醒过你的那个。

这是一个临时的签名链接：存储没有对外开放，而这个链接是你用自己的密钥生成的。它能存活一周——对工作坊以及之后做实验来说都绰绰有余。
