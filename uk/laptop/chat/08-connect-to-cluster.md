## 8. Заходимо в кластер

**Підключаємося до свого тенанта**

📍 **Де:** дашборд відкриваємо в браузері, команди виконуємо на ноутбуці.

**Ваші доступи:**
```
dashboard: https://dashboard.workshop.aenix.io
login:   workshopXX      ← ваш номер, скажу особисто
password:  ...             ← скажу особисто
```

1. Відкрийте дашборд за посиланням вище.
2. Увійдіть під своїм логіном.
3. У дашборді: **Info → вкладка Secrets → `kubeconfig-tenant-workshopXX`**. Натисніть *Reveal*,
   скопіюйте вміст.
4. Збережіть у файл і вкажіть на нього змінну:

**macOS і Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # вставте скопійоване, збережіть
export KUBECONFIG=~/.kube/workshop
```

**Windows** (PowerShell)
```powershell
notepad $HOME\.kube\workshop   # вставте, збережіть
$env:KUBECONFIG = "$HOME\.kube\workshop"
```

**Перевіряємо:**
```
kubectl get vminstance -n tenant-workshopXX
```
Відкриється браузер — залогіньтеся як `workshopXX`. Після цього команда має відповісти
`No resources found`. Це правильна відповідь: машин поки немає, але кластер вас упізнав.

⚠️ Дві речі, на яких спотикаються найчастіше:
• `KUBECONFIG` має вказувати рівно на той файл, куди ви вставили конфіг.
• `kubectl get vm` і `kubectl get vmi` працювати не будуть — під вашим обліковим записом
  доступний `vminstance`. Так і задумано.

⚠️ **`x509: certificate signed by unknown authority`** — друга часта помилка, майже
завжди на Windows. Означає вона не проблему із сертифікатом, а те, що `kubectl` узяв
**не той файл доступу**: довіра до внутрішнього центру сертифікації кластера лежить у вашому
kubeconfig, у полі `certificate-authority-data`, а у файлі за замовчуванням його немає.

Розбираємося покроково, у PowerShell:
```powershell
$env:KUBECONFIG
# порожньо — означає береться файл за замовчуванням, а не той, що вам видали

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — файл збережено неповністю, завантажте секрет із дашборда заново

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# має починатися з apiVersion; квадратики або порожнеча — файл у UTF-16
```

Третій пункт — найпідступніша пастка Windows. Блокнот і перенаправлення `>` зберігають
файл у **UTF-16**, а `kubectl` такий файл не читає. Зберігати лише в UTF-8: у Блокноті
тип файлу «Усі файли», а з команди — через `Out-File -Encoding utf8`, не через `>`.
