## 10. 教材を入手して、自分の番号を埋め込む

**マニフェストのリポジトリ**

📍 **場所:** あなたのノートPC上、ターミナルの中です。ホームディレクトリに置きます。そうすればパスが全員で同じになり、私も手伝いやすくなります。

**ターミナルをどこで開くか:**
• macOS — Spotlight(`Cmd+Space`)で「Terminal」と入力
• Linux — ほとんどの環境で `Ctrl+Alt+T`
• Windows —「スタート」メニューで「PowerShell」と入力

**ファイルの入ったフォルダを入手する**(3つのコマンドを1つずつ):
```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```
最初のコマンドはあなたをホームディレクトリへ移動させ、2つ目は教材フォルダをそこへダウンロードし、3つ目はその中へ入ります。ここから先、すべてのコマンドは**ここから**実行します。コマンド内のパスは、このフォルダを基準とした相対パスで書かれています。

**何がダウンロードされたか見てみましょう:**
```bash
ls manifests scripts
```
マニフェストが4つ、スクリプトが4つ見えるはずです。ファイルマップにあったものそのものです。

**ターミナルを閉じてしまったり、迷子になったら** — 戻り方はいつも同じです:
```bash
cd ~/cozystack-migration-workshop/workshop
```
Windows でもパスは同じです:`cd $HOME\cozystack-migration-workshop\workshop`。
今どこにいるか確認するには:`pwd`(PowerShell でも動きます)。

⚠️ 末尾の `/workshop` は必須です。リポジトリには、ワークショップ教材のとなりに、独立したラボが入った `labs` フォルダもあります。1つ上の階層で止まってしまうと、コマンドは `manifests` も `scripts` も見つけられません。

**編集のためにファイルを開くには何を使うか。** マニフェストはただのテキストファイルなので、何でも構いません:
• ターミナルで — `nano manifests/03-app-vm.yaml`(保存: `Ctrl+O`、`Enter`、終了: `Ctrl+X`)
• macOS でマウスを使って — `open -a TextEdit manifests/03-app-vm.yaml`
• Windows でマウスを使って — `notepad manifests\03-app-vm.yaml`
• VS Code が入っているなら — `code .` でフォルダ全体を一度に開けて、これが一番便利です

⚠️ `.yaml` ファイルを Word や Google Docs で開かないでください。引用符やダッシュが勝手に置き換えられ、そのあとファイルが適用できなくなり、しかもエラーは訳が分からないように見えます。

すべてのファイルに `tenant-workshopXX` というプレースホルダーが入っています。自分の番号を一度にすべて埋め込んでください。そうしないとマニフェストが違う場所へ届いてしまいます。あなたのログインが `workshop03` だとしましょう:

**Linux**
```bash
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**macOS**(ここでは `sed` の構文が異なります — 空の引用符に注意してください)
```bash
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**Windows**(PowerShell)
```powershell
Get-ChildItem -Recurse manifests,scripts -File | ForEach-Object {
  (Get-Content $_.FullName) -replace 'tenant-workshopXX','tenant-workshop03' | Set-Content $_.FullName
}
```

**プレースホルダーが1つも残っていないか確認します:**
```bash
grep -rn tenant-workshopXX manifests scripts || echo "clean, you can continue"
```

コマンドが触らない箇所が1つあります。`manifests/03-app-vm.yaml` の `url: "ВСТАВЬТЕ_PRESIGNED_URL"` という行です。この URL は、イメージを変換したときに得られます。今のところは、そこであなたを待っているとだけ覚えておいてください。
