## 8. クラスターへのログイン

**自分のテナントへ接続する**

📍 **場所:** ダッシュボードはブラウザで開き、コマンドはノートパソコンで実行します。

**あなたの認証情報:**
```
dashboard: https://dashboard.workshop.aenix.io
login:     workshopXX      ← your number, I'll tell you in person
password:  ...             ← I'll tell you in person
```

1. 上のリンクからダッシュボードを開きます。
2. 自分のログインでログインします。
3. ダッシュボードで: **Info → Secrets タブ → `kubeconfig-tenant-workshopXX`**。*Reveal* をクリックして
   内容をコピーします。
4. ファイルに保存し、変数をそれに向けます:

**macOS と Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # paste what you copied, then save
export KUBECONFIG=~/.kube/workshop
```

**Windows**（PowerShell）
```powershell
notepad $HOME\.kube\workshop   # paste, then save
$env:KUBECONFIG = "$HOME\.kube\workshop"
```

**確認しましょう:**
```
kubectl get vminstance -n tenant-workshopXX
```
ブラウザが開きます — `workshopXX` としてログインしてください。その後、コマンドは
`No resources found` と返すはずです。これが正しい応答です。マシンはまだありませんが、クラスターはあなたを認識しています。

⚠️ 最もよくつまずく点が2つあります:
• `KUBECONFIG` は、設定を貼り付けたまさにそのファイルを指している必要があります。
• `kubectl get vm` と `kubectl get vmi` は動きません — あなたのアカウントでは `vminstance` タイプが
  利用可能です。これは意図的な仕様です。

⚠️ **`x509: certificate signed by unknown authority`** — 2つ目のよくあるエラーで、ほぼ
必ず Windows で起きます。これは証明書に問題があるという意味ではなく、`kubectl` が
**間違ったアクセスファイル**を拾ったという意味です。クラスターの内部認証局への信頼はあなたの
kubeconfig の `certificate-authority-data` フィールドにあり、デフォルトのファイルにはそれがありません。

PowerShell でステップごとに確認していきましょう:
```powershell
$env:KUBECONFIG
# empty — means it's using the default file, not the one you were given

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — the file was saved incompletely; download the secret from the dashboard again

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# should start with apiVersion; little squares or emptiness mean the file is in UTF-16
```

3つ目の点は Windows の最も厄介な落とし穴です。メモ帳と `>` によるリダイレクトは、ファイルを
**UTF-16** で保存してしまい、`kubectl` はそれを読み込めません。保存は必ず UTF-8 で行ってください。
メモ帳ではファイルの種類として「すべてのファイル」を選び、コマンドラインからは `>` ではなく
`Out-File -Encoding utf8` を使います。
