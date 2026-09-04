## 9. git のインストール

**最後のツール — これで教材を取得します**

📍 **場所:** ノートPC。

まず、すでに入っていないか確認しましょう。macOS と多くの Linux ビルドでは git が
プリインストールされています。
```
git --version
```
バージョンが表示されたら、このメッセージは飛ばして構いません。

**macOS。** 一番簡単なのはシステムのダイアログに任せる方法です。`git --version` と入力すると、
git が未インストールなら macOS が自動で開発者ツールのインストールを提案します。承諾してください。
あるいは明示的に:
```bash
xcode-select --install
```
Homebrew を使う場合:
```bash
brew install git
```

**Linux** — ディストリビューションの系統によって異なります:
```bash
sudo apt-get update && sudo apt-get install -y git    # Debian, Ubuntu
sudo dnf install -y git                               # Fedora, RHEL, CentOS Stream
```

**Windows**（PowerShell）:
```powershell
winget install -e --id Git.Git
```
その後、PowerShell を一度閉じて開き直してください。そうしないとコマンドが見つかりません。

⚠️ **`winget` が見つからない場合** — git は通常のインストーラーでも入ります。
https://git-scm.com/download/win を開き、ファイルをダウンロードして実行し、各ステップで
「次へ」を押していくだけで、何も変更する必要はありません。インストール後は新しい PowerShell
ウィンドウを開いてください。あるいは git を使わず、下の Download ZIP の方法で済ませることもできます。

**確認しましょう:**
```
git --version
```

🖱 **git をインストールしたくない場合** — git が必要なのはファイルのフォルダをダウンロードする
一度きりです。ブラウザだけで済ませられます。
https://github.com/aenix-org/cozystack-migration-workshop を開き、緑色の
**Code → Download ZIP** ボタンを押してアーカイブを展開してください。その後はすべて同じで、
`cd cozystack-migration-workshop` の代わりに展開したフォルダに入るだけです。
