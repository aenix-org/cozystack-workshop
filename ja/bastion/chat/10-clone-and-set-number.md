## 10. 教材はすでに bastion 上にあります

**クローンするものはありません**

📍 **場所:** SSH でログインしたばかりの bastion 上です。

教材フォルダはすでにホームディレクトリに置かれており、**あなたのテナント番号もすでに埋め込まれています**。`tenant-workshopXX` というプレースホルダーは、bastion の準備時にあなたの `tenant-workshopNN` へ置き換え済みです。検索して置換する作業は不要で、ファイルをそのまま適用するだけです。

フォルダに入って、中身を見てみましょう:

```bash
cd ~/workshop
ls manifests scripts
```

マニフェストが4つ、スクリプトが4つ見えるはずです。ファイルマップにあったものそのものです。埋め込まれた番号があなたのものであることを確認しましょう:

```bash
grep -m1 namespace manifests/01-bucket.yaml
```

`namespace:` の行には、`tenant-workshopXX` ではなく、あなたの `tenant-workshopNN` が入っています。

**迷子になったら**、戻り方はいつも同じです:
```bash
cd ~/workshop
```

**編集のためにファイルを開くには何を使うか。** これが必要になるのはちょうど一度だけ、第3フェーズで presigned URL を `manifests/03-app-vm.yaml` に貼り付けるときです。`nano` で十分です:
`nano manifests/03-app-vm.yaml`(保存: `Ctrl+O`、`Enter`、終了: `Ctrl+X`)。

意図的に残された唯一のプレースホルダーは、`manifests/03-app-vm.yaml` の
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` という行です。この URL は、イメージを変換したときに得られます。今のところは、そこであなたを待っているとだけ覚えておいてください。
