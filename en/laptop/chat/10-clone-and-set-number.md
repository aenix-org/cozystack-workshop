## 10. Getting the materials and filling in your number

**The manifests repository**

📍 **Where:** on your laptop, in the terminal. We'll put it in your home directory — that way the path is the same for everyone, and it's easier for me to help you.

**Where to open the terminal:**
• macOS — Spotlight (`Cmd+Space`), type "Terminal"
• Linux — `Ctrl+Alt+T` in most environments
• Windows — the "Start" menu, type "PowerShell"

**Grab the folder with the files** (three commands, one at a time):
```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```
The first command takes you to your home directory, the second downloads the materials
folder into it, and the third moves inside it. From here on, every command is run **from here** —
the paths in them are written relative to this folder.

**See what was downloaded:**
```bash
ls manifests scripts
```
You should see four manifests and four scripts — the very ones from the file map.

**If you closed the terminal or got lost** — the way back is always the same:
```bash
cd ~/cozystack-migration-workshop/workshop
```
On Windows the path is the same: `cd $HOME\cozystack-migration-workshop\workshop`.
To check where you are: `pwd` (works in PowerShell too).

⚠️ The `/workshop` tail is mandatory. Next to the workshop materials the repository holds a `labs`
folder with standalone labs — if you stop one level higher, the commands will find neither
`manifests` nor `scripts`.

**What to open files with for editing.** Manifests are plain text files, so anything will do:
• in the terminal — `nano manifests/03-app-vm.yaml` (save: `Ctrl+O`, `Enter`, exit: `Ctrl+X`)
• with the mouse on macOS — `open -a TextEdit manifests/03-app-vm.yaml`
• with the mouse on Windows — `notepad manifests\03-app-vm.yaml`
• if you have VS Code installed — `code .` opens the whole folder at once, which is the most convenient

⚠️ Don't open `.yaml` files in Word or Google Docs: they swap out quotes and dashes,
after which the file stops applying and the error looks inexplicable.

Every file carries the placeholder `tenant-workshopXX`. Fill in your number everywhere at once,
otherwise the manifest will go to the wrong place. Say your login is `workshop03`:

**Linux**
```bash
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**macOS** (here `sed` has a different syntax — note the empty quotes)
```bash
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**Windows** (PowerShell)
```powershell
Get-ChildItem -Recurse manifests,scripts -File | ForEach-Object {
  (Get-Content $_.FullName) -replace 'tenant-workshopXX','tenant-workshop03' | Set-Content $_.FullName
}
```

**Check that not a single placeholder is left:**
```bash
grep -rn tenant-workshopXX manifests scripts || echo "clean, you can continue"
```

There is one spot the command won't touch: in `manifests/03-app-vm.yaml`, the line
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`. You'll get that URL later, once you convert the image.
For now, just know it's waiting for you there.
