## 9. 安装 git

**最后一个工具——我们用它来获取材料**

📍 **位置：** 在你的笔记本上。

先检查一下，说不定你已经装好了：在 macOS 和大多数 Linux 发行版里，git 是预装的。
```
git --version
```
如果它打印出了版本号——就跳过这条消息。

**macOS。** 最省事的办法是让系统对话框替你完成：输入 `git --version`，如果
git 没安装，macOS 会自动提示安装开发者工具。接受它即可。
或者显式安装：
```bash
xcode-select --install
```
用 Homebrew：
```bash
brew install git
```

**Linux**——取决于发行版家族：
```bash
sudo apt-get update && sudo apt-get install -y git    # Debian、Ubuntu
sudo dnf install -y git                               # Fedora、RHEL、CentOS Stream
```

**Windows**（PowerShell）：
```powershell
winget install -e --id Git.Git
```
然后关闭 PowerShell 再重新打开，否则会找不到这个命令。

⚠️ **如果找不到 `winget`**——git 也可以用普通安装程序装：打开
https://git-scm.com/download/win，下载文件，运行它，在每一步都点「下一步」，
什么都不用改。安装完成后——开一个新的 PowerShell 窗口。
或者干脆不用 git——改用下面的 Download ZIP 方案。

**来验证一下：**
```
git --version
```

🖱 **如果你不想安装 git**——它只在一处用到，就是下载那个文件夹。
用浏览器也能搞定：打开
https://github.com/aenix-org/cozystack-migration-workshop，点绿色的
**Code → Download ZIP** 按钮，解压压缩包。之后的一切都完全一样，
只是不再执行 `cd cozystack-migration-workshop`，而是进入解压出来的文件夹。
