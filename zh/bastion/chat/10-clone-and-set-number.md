## 10. 材料已经在 bastion 上了

**无需克隆任何东西**

📍 **位置：** 在你刚刚通过 SSH 登录进去的 bastion 上。

材料文件夹已经放在你的主目录里，而且**你的租户编号已经填好了**。准备 bastion 时，`tenant-workshopXX` 占位符已被替换成你的 `tenant-workshopNN`——不需要查找和替换任何东西，直接照原样应用这些文件即可。

进入该文件夹，看看里面有什么：

```bash
cd ~/workshop
ls manifests scripts
```

你应该会看到四个清单（manifest）和四个脚本——正是文件地图里的那些。确认填进去的编号就是你的：

```bash
grep -m1 namespace manifests/01-bucket.yaml
```

`namespace:` 这一行里会是你的 `tenant-workshopNN`，而不是 `tenant-workshopXX`。

**如果你迷路了**，返回的方式始终一样：
```bash
cd ~/workshop
```

**用什么打开文件来编辑。** 你只会用到这一次——在第三阶段把预签名链接（presigned URL）粘贴进 `manifests/03-app-vm.yaml`。用 `nano` 就行：
`nano manifests/03-app-vm.yaml`（保存：`Ctrl+O`、`Enter`，退出：`Ctrl+X`）。

唯一被有意保留下来的占位符在 `manifests/03-app-vm.yaml` 里，即这一行
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`。等你转换完镜像就会拿到那个链接。现在只需知道它正在那里等着你。
