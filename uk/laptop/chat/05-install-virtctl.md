## 5. Встановлюємо virtctl

**virtctl — керування віртуальними машинами**

⚠️ **Увага: ставимо не найсвіжішу версію, а ту, що в кластері.** Клієнт, новіший за сервер, змінює синтаксис команд, і половина запитань на минулих воркшопах була саме через це. У нашому кластері **v1.8.4** — саме її вказано в усіх блоках нижче. Не міняйте її на latest.

**macOS**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-darwin-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```
Якщо macOS скаржиться «не вдалося перевірити розробника»:
```bash
sudo xattr -d com.apple.quarantine /usr/local/bin/virtctl
```

**Linux**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-linux-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```

**Windows** (PowerShell, запускати від звичайного користувача)
```powershell
$ver = "v1.8.4"
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
Після цього **закрийте вікно PowerShell і відкрийте нове** — інакше оновлений PATH не підхопиться.

**Перевіряємо (скрізь однаково):**
```
virtctl version
```
Має з'явитися рядок `Client Version:` з номером. Скарга на відсутність зв'язку із сервером на цьому кроці — це нормально: ми до нього ще не підключалися.

**Про ім'я машини в командах.** З клієнтом v1.8.4 машина вказується голим ім'ям, без приставки: `vm-instance-app-1`. Якщо у вас усе ж встановився новіший клієнт і він відповідає `target must contain type and name separated by '/'` — додайте приставку **`vmi/`**: `vmi/vm-instance-app-1`.

⚠️ Приставка саме `vmi/`, а не `vm/`. З `vm/` прийде відмова за правами (`cannot get resource "virtualmachines/portforward"`): учаснику видано права на запущені екземпляри машин, а не на їхні описи.
