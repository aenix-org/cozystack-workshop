## 9. Встановлюємо git

**Останній інструмент — ним заберемо матеріали**

📍 **Де:** на ноутбуці.

Спершу перевірте, раптом він уже є: на macOS і в більшості збірок Linux git
встановлений заздалегідь.
```
git --version
```
Якщо відповіла версія — пропускайте це повідомлення.

**macOS.** Найпростіше — дочекатися системного вікна: наберіть `git --version`, і якщо
git не встановлено, macOS сама запропонує поставити інструменти розробника. Погоджуйтесь.
Або явно:
```bash
xcode-select --install
```
З Homebrew:
```bash
brew install git
```

**Linux** — залежить від сімейства дистрибутива:
```bash
sudo apt-get update && sudo apt-get install -y git    # Debian, Ubuntu
sudo dnf install -y git                               # Fedora, RHEL, CentOS Stream
```

**Windows** (PowerShell):
```powershell
winget install -e --id Git.Git
```
Потім закрийте і відкрийте PowerShell заново, інакше команда не знайдеться.

⚠️ **Якщо `winget` не знайдено** — git ставиться звичайним інсталятором: відкрийте
https://git-scm.com/download/win, завантажте файл, запустіть і тисніть «Далі» на всіх
кроках, нічого міняти не треба. Після встановлення — нове вікно PowerShell.
Або обійдіться без git — варіантом з Download ZIP нижче.

**Перевіряємо:**
```
git --version
```

🖱 **Якщо ставити git не хочеться** — він потрібен рівно один раз, щоб завантажити папку
з файлами. Можна обійтися браузером: відкрийте
https://github.com/aenix-org/cozystack-migration-workshop, натисніть зелену кнопку
**Code → Download ZIP** і розпакуйте архів. Далі все те саме, тільки замість
`cd cozystack-migration-workshop` заходьте в розпаковану папку.
