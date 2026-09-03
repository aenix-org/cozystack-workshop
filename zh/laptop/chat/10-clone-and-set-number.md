## 10. 获取材料并填入你的编号

**清单仓库**

📍 **位置：** 在你的笔记本上，在终端里。我们会把它放到你的主目录里——这样每个人的路径都一样，我也更容易帮你。

**在哪里打开终端：**
• macOS — Spotlight（`Cmd+Space`），输入「Terminal」
• Linux — 大多数环境里按 `Ctrl+Alt+T`
• Windows — 「开始」菜单，输入「PowerShell」

**把装着文件的文件夹取下来**（三条命令，一次一条）：
```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```
第一条命令把你带到主目录，第二条把材料文件夹下载进去，第三条进入它的内部。从这里开始，每一条命令都是**从这里**执行的——命令里的路径都是相对于这个文件夹写的。

**看看下载了什么：**
```bash
ls manifests scripts
```
你应该会看到四个清单（manifest）和四个脚本——正是文件地图里的那些。

**如果你关掉了终端或迷路了**——返回的方式始终一样：
```bash
cd ~/cozystack-migration-workshop/workshop
```
在 Windows 上路径是一样的：`cd $HOME\cozystack-migration-workshop\workshop`。查看你现在在哪里：`pwd`（在 PowerShell 里也管用）。

⚠️ 末尾的 `/workshop` 是必需的。仓库里在工作坊材料的旁边还有一个 `labs` 文件夹，里面是独立的实验——如果你停在上一层，命令既找不到 `manifests` 也找不到 `scripts`。

**用什么打开文件来编辑。** 清单都是纯文本文件，所以用什么都行：
• 在终端里——`nano manifests/03-app-vm.yaml`（保存：`Ctrl+O`、`Enter`，退出：`Ctrl+X`）
• 在 macOS 上用鼠标——`open -a TextEdit manifests/03-app-vm.yaml`
• 在 Windows 上用鼠标——`notepad manifests\03-app-vm.yaml`
• 如果装了 VS Code——`code .` 会一次打开整个文件夹，这是最方便的

⚠️ 不要用 Word 或 Google Docs 打开 `.yaml` 文件：它们会把引号和连字符替换掉，之后文件就无法应用了，而报错看上去莫名其妙。

每个文件里都有占位符 `tenant-workshopXX`。一次性把你的编号填到所有地方，否则清单会跑到错误的位置。假设你的登录名是 `workshop03`：

**Linux**
```bash
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**macOS**（这里 `sed` 的语法不一样——注意那对空引号）
```bash
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**Windows**（PowerShell）
```powershell
Get-ChildItem -Recurse manifests,scripts -File | ForEach-Object {
  (Get-Content $_.FullName) -replace 'tenant-workshopXX','tenant-workshop03' | Set-Content $_.FullName
}
```

**检查一个占位符都没剩下：**
```bash
grep -rn tenant-workshopXX manifests scripts || echo "clean, you can continue"
```

有一个地方这条命令不会碰到：`manifests/03-app-vm.yaml` 里的那一行 `url: "ВСТАВЬТЕ_PRESIGNED_URL"`。那个链接你会稍后拿到，就在你转换完镜像之后。现在只需知道它正在那里等着你。
