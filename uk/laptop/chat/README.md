# Повідомлення для чату воркшопу

Один файл — одне повідомлення. Надсилайте їх по ходу практики, а не всі одразу: інакше
учасники забіжать наперед і застрягнуть там, де ви ще не пояснили, навіщо це потрібно.

Скрізь, де трапляється `workshopXX`, учасник підставляє свій номер: `workshop03`,
`workshop07` і так далі. Номер видається особисто кожному разом із паролем.

Кожен файл укладається в ліміт Telegram — 4096 символів.

| № | Повідомлення | Файл |
|---|---|---|
| 1 | Що ми взагалі робимо | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | Словничок: як це називається у вас і як тут | [`02-glossary.md`](02-glossary.md) |
| 3 | Перед початком: що знадобиться | [`03-prerequisites.md`](03-prerequisites.md) |
| 4 | Встановлюємо kubectl | [`04-install-kubectl.md`](04-install-kubectl.md) |
| 5 | Встановлюємо virtctl | [`05-install-virtctl.md`](05-install-virtctl.md) |
| 6 | Встановлюємо kubelogin | [`06-install-kubelogin.md`](06-install-kubelogin.md) |
| 7 | Про krew — і чому ми ним не користуємося | [`07-about-krew.md`](07-about-krew.md) |
| 8 | Заходимо в кластер | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 9 | Встановлюємо git | [`09-install-git.md`](09-install-git.md) |
| 10 | Забираємо матеріали і підставляємо свій номер | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | Карта файлів: що де лежить і де запускається | [`11-file-map.md`](11-file-map.md) |
| 12 | Фаза 1. Вивозимо образ із vSphere | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | Розбір: що всередині 01-bucket.yaml | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | Крок 1: своє сховище | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | Розбір: що всередині 02-conversion-vm.yaml | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | Крок 2: машина-конвертер | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | Розбір: що робить convert.sh | [`17-convert-script.md`](17-convert-script.md) |
| 18 | Крок 3: конвертація образу | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | Фаза 2. Заводимо машину на новому місці | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | Розбір: що всередині 03-app-vm.yaml | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | Крок 4: ваша віртуальна машина | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | Фаза 3. Викидаємо звіринець | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | Розбір: що всередині 04-managed.yaml | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | Крок 5: база і черга з каталогу | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | Крок 6: лагодимо мережу всередині машини | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | Перша перевірка: пробуємо запустити і ловимо помилку | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | Крок 7: перемикаємо застосунок на керовані сервіси | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | Крок 8: чому застосунок усе ще падає | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | Крок 8: встановлюємо клієнт і накатуємо схему | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | Крок 9: перевіряємо весь ланцюжок | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | Якщо щось не працює | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | Після воркшопу | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
