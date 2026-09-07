## 10. Отримуємо матеріали і підставляємо свій номер

**Репозиторій з маніфестами**

📍 **Де:** на ноутбуці, у терміналі. Складаємо в домашню теку — так шлях буде
однаковий у всіх, і мені простіше вам допомагати.

**Де відкрити термінал:**
• macOS — Spotlight (`Cmd+Space`), наберіть «Термінал»
• Linux — `Ctrl+Alt+T` у більшості середовищ
• Windows — меню «Пуск», наберіть «PowerShell»

**Забираємо теку з файлами** (три команди, по одній):
```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```
Перша команда переводить вас у домашню теку, друга завантажує туди теку
з матеріалами, третя заходить усередину неї. Далі всі команди виконуються **звідси** —
шляхи в них написані відносно цієї теки.

**Подивіться, що завантажилося:**
```bash
ls manifests scripts
```
Маєте побачити чотири маніфести і чотири скрипти — ті самі, з карти файлів.

**Якщо закрили термінал або загубилися** — повернутися завжди однаково:
```bash
cd ~/cozystack-migration-workshop/workshop
```
На Windows шлях той самий: `cd $HOME\cozystack-migration-workshop\workshop`.
Перевірити, де ви зараз: `pwd` (у PowerShell теж працює).

⚠️ Хвіст `/workshop` обов'язковий. У репозиторії поряд з матеріалами воркшопу лежить тека
`labs` із самостійними лабами — якщо зупинитися на рівень вище, команди не знайдуть
ні `manifests`, ні `scripts`.

**Чим відкривати файли для редагування.** Маніфести — звичайні текстові файли, годиться
будь-що:
• у терміналі — `nano manifests/03-app-vm.yaml` (зберегти: `Ctrl+O`, `Enter`, вийти: `Ctrl+X`)
• мишкою на macOS — `open -a TextEdit manifests/03-app-vm.yaml`
• мишкою на Windows — `notepad manifests\03-app-vm.yaml`
• якщо встановлено VS Code — `code .` відкриє всю теку одразу, це найзручніше

⚠️ Не відкривайте `.yaml` у Word чи Google Docs: вони підмінюють лапки й дефіси,
після чого файл перестає застосовуватися, а помилка виглядає незрозуміло.

У всіх файлах стоїть заповнювач `tenant-workshopXX`. Підставте свій номер одразу і всюди,
інакше маніфест поїде не туди. Припустімо, ваш логін `workshop03`:

**Linux**
```bash
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**macOS** (тут у `sed` інший синтаксис — зверніть увагу на порожні лапки)
```bash
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**Windows** (PowerShell)
```powershell
Get-ChildItem -Recurse manifests,scripts -File | ForEach-Object {
  (Get-Content $_.FullName) -replace 'tenant-workshopXX','tenant-workshop03' | Set-Content $_.FullName
}
```

**Перевіряємо, що не залишилося жодного заповнювача:**
```bash
grep -rn tenant-workshopXX manifests scripts || echo "clean, you can continue"
```

Одне місце команда не зачепить: у `manifests/03-app-vm.yaml` рядок
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`. Це посилання ви отримаєте пізніше, коли сконвертуєте образ.
Поки — знайте, що воно вас там чекає.
