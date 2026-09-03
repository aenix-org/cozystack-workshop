## 9. Installing git

**The last tool — we'll use it to grab the materials**

📍 **Where:** on your laptop.

First check whether you already have it: on macOS and in most Linux builds git
comes preinstalled.
```
git --version
```
If it printed a version — skip this message.

**macOS.** The easiest way is to let the system dialog do the work: type `git --version`, and if
git isn't installed, macOS will offer to install the developer tools on its own. Accept it.
Or explicitly:
```bash
xcode-select --install
```
With Homebrew:
```bash
brew install git
```

**Linux** — depends on the distribution family:
```bash
sudo apt-get update && sudo apt-get install -y git    # Debian, Ubuntu
sudo dnf install -y git                               # Fedora, RHEL, CentOS Stream
```

**Windows** (PowerShell):
```powershell
winget install -e --id Git.Git
```
Then close PowerShell and open it again, otherwise the command won't be found.

⚠️ **If `winget` isn't found** — git installs with an ordinary installer: open
https://git-scm.com/download/win, download the file, run it and click "Next" on every
step, nothing needs changing. After installation — a new PowerShell window.
Or do without git — use the Download ZIP option below.

**Let's check:**
```
git --version
```

🖱 **If you'd rather not install git** — it's needed exactly once, to download the folder
of files. You can get by with a browser: open
https://github.com/aenix-org/cozystack-migration-workshop, click the green
**Code → Download ZIP** button and unpack the archive. Everything after that is the same,
only instead of `cd cozystack-migration-workshop` you go into the unpacked folder.
