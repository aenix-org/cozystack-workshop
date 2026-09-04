## 7. krew について — そして、なぜ使わないのか

**手短に言うと: 今日はインストールしないでください**

krew は kubectl のプラグインマネージャーで、同じ virtctl や kubelogin もこれで入れられます。
ですが、過去のワークショップでいちばん時間を食ったのが、まさにこの krew でした。特に Windows で顕著でした。
ステップ 3 と 4 を終えているなら、**もう必要なものはすべて揃っています。この投稿は飛ばしてください**。

krew をすでに入れている、あるいはどうしても使いたい場合だけ、この先を読んでください。

⚠️ **Windows で踏みがちな 3 つの落とし穴 — いずれも実際に遭遇したものです:**
• **現在のウィンドウで PATH が更新されていない。** いちばんよくあるケースです。同じセッション内で直せます:
  `$env:Path += ";$HOME\.krew\bin"`
• **krew.exe のインストールが完了していない** — SmartScreen かウイルス対策ソフトに止められています。確認方法:
  `Test-Path "$HOME\.krew\bin\kubectl-krew.exe"`
• **管理者権限の PowerShell ウィンドウと通常のウィンドウは別世界です。** `$HOME` も
  ユーザー PATH も異なります。管理者でインストールして通常ユーザーで実行すると、
  プラグインは永久に見つかりません。同じ通常ウィンドウでインストールも実行も行ってください。

**macOS と Linux** — ブロックをまるごとコピーしてください。システムは自動で判別します:
```bash
set -x; cd "$(mktemp -d)" &&
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64$/arm64/')" &&
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-${OS}_${ARCH}.tar.gz" &&
tar zxvf "krew-${OS}_${ARCH}.tar.gz" &&
./"krew-${OS}_${ARCH}" install krew
```
次に krew を PATH に追加します。この行はプロファイルに書き足す必要があります。そうしないと
次回ターミナルを起動したときに忘れられてしまいます:
```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc   # zsh 用、macOS のデフォルト
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc  # bash 用、たいていは Linux
source ~/.zshrc    # または source ~/.bashrc
```

**Windows**（PowerShell）
```powershell
Invoke-WebRequest -Uri "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.exe" -OutFile "$HOME\krew.exe"
& "$HOME\krew.exe" install krew
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\.krew\bin", "User")
Remove-Item "$HOME\krew.exe"
```
PowerShell をもう一度閉じて開き直してください。

**プラグインをインストールします:**
```bash
kubectl krew install virt
kubectl krew install oidc-login
```

⚠️ 重要な違い: krew 経由でインストールすると、コマンド名が変わります —
`virtctl console …` ではなく `kubectl virt console …` になります。この先の手順では
`virtctl` と書きますが、krew で入れた場合は頭の中で `kubectl virt` に読み替えてください。
混乱しないように、短いエイリアスを設定しておくとよいでしょう:
```bash
alias virtctl="kubectl virt"
```
