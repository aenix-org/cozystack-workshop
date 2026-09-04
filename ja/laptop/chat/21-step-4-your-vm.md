## 21. ステップ4: あなたの仮想マシン

**自分のイメージからマシンを起動する**

📍 **場所:** ノートPC。

⚠️ **まず、変換用マシンを停止してください** — 役目を終え、クォータの 8Gi を占有しています。
削除しないと、新しいマシンは `Pending` のまま止まり、
テスト環境が壊れたように見えます。過去のワークショップでは、ほぼ全員がここで詰まりました:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

イメージはバケットに残ります — ここからマシンを起動します。

次に `manifests/03-app-vm.yaml` を開き、署名付きリンク（presigned）を `url` フィールドに貼り付けて
適用します:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

まず、クラスターがリンクからイメージをダウンロードし、各レプリカに分散配置します — これには 1〜2 分かかります。
その後、マシンが起動します。

中に入ってみましょう:
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

**マシンへのアクセス:**
```
login:    root
password: cozydemo
```

コンソールから抜けるには `Ctrl+]` です。

**ここでも変換用マシンと同じ 2 つのオブジェクトの組み合わせです**。ただしディスクは
カタログから取得するのではなく、あなたのリンクからダウンロードされます:

• **VM Disk** `app-1` — 10Gi、source = http、あの署名付き URL
• **VM Instance** `app-1` — プロファイル `centos.7`、instance type `u1.medium`

名前が一致していますが、問題ありません: ディスクとマシンは異なるオブジェクトタイプです。`virtctl`
コマンドでは、前回と同様、マシンは接頭辞付きで指定します: **`vm-instance-app-1`**。

🖱 **ダッシュボード経由:** **1)** **VM Disk → Deploy new**: 名前 `app-1`、source = **http**、
URL フィールドに署名付きリンク、サイズ `10Gi`、storage class `replicated`。
**2)** **VM Instance → Deploy new**: 名前 `app-1`、instance type `u1.medium`、
プロファイル `centos.7`、ディスク — `app-1`。コンソールは、マシンのページの **VNC** ボタンです。

いま行ったことに注目してください: 仮想マシンをテキストで記述し、
たった 1 つのコマンドで適用しました。このファイルをリポジトリに置けば、
同じマシンを 100 台、クリック 1 回もせずに起動できます。
