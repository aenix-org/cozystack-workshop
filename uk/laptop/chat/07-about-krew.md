## 7. Про krew — і чому ми ним не користуємося

**Коротка відповідь: не ставте його сьогодні**

krew — менеджер плагінів для kubectl, і ним можна поставити ті самі virtctl та kubelogin.
Але на минулих воркшопах саме він з’їв найбільше часу, особливо на Windows.
Якщо ви зробили кроки 3 і 4 — **у вас уже все є, цей пост пропускайте**.

Читайте далі, тільки якщо krew у вас уже стоїть або дуже хочеться.

⚠️ **Три граблі Windows, усі траплялися вживу:**
• **PATH не оновився в поточному вікні.** Найчастіше. Лікується прямо в тій самій сесії:
  `$env:Path += ";$HOME\.krew\bin"`
• **krew.exe не доустановився** — SmartScreen або антивірус його прибили. Перевірити:
  `Test-Path "$HOME\.krew\bin\kubectl-krew.exe"`
• **Адмінське та звичайне вікно PowerShell — це різні світи.** У них різні `$HOME`
  і різний користувацький PATH. Поставили від адміністратора, запускаєте звичайним —
  плагін не знайдеться ніколи. Ставте і запускайте в одному й тому самому звичайному вікні.

**macOS і Linux** — копіюйте блок цілком, він сам визначить систему:
```bash
set -x; cd "$(mktemp -d)" &&
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64$/arm64/')" &&
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-${OS}_${ARCH}.tar.gz" &&
tar zxvf "krew-${OS}_${ARCH}.tar.gz" &&
./"krew-${OS}_${ARCH}" install krew
```
Потім додайте krew у PATH — рядок треба дописати у свій профіль, інакше він забудеться
під час наступного запуску термінала:
```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc   # для zsh, це за замовчуванням у macOS
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc  # для bash, зазвичай Linux
source ~/.zshrc    # або source ~/.bashrc
```

**Windows** (PowerShell)
```powershell
Invoke-WebRequest -Uri "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.exe" -OutFile "$HOME\krew.exe"
& "$HOME\krew.exe" install krew
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\.krew\bin", "User")
Remove-Item "$HOME\krew.exe"
```
Знову закрийте і відкрийте PowerShell.

**Ставимо плагіни:**
```bash
kubectl krew install virt
kubectl krew install oidc-login
```

⚠️ Важлива відмінність: під час встановлення через krew команда називається інакше —
`kubectl virt console …` замість `virtctl console …`. Далі в інструкціях я пишу
`virtctl` — якщо ставили через krew, подумки підставляйте `kubectl virt`.
Щоб не плутатися, можна зробити короткий псевдонім:
```bash
alias virtctl="kubectl virt"
```
