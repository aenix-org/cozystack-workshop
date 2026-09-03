## 31. うまくいかないとき

**よくつまずくポイントの短いリスト**

• **アプリケーションに外部からアクセスできない。** 移行した CentOS でよくある原因は、組み込みのファイアウォールです。ポート 8080 を塞いでいます:
  ```bash
  systemctl stop firewalld
  ```

• **`kubectl` が「forbidden」と返す。** 自分の namespace に接続しているか確認してください:
  `-n tenant-workshopXX`。そして、利用できるのは `vminstance` であって、`vm` や `vmi` ではないことを覚えておいてください。

• **注文が作成されないのに、ヘルスは `200` を返す。** テーブルが作成されていません。データベーススキーマに関するメッセージに戻ってください。

• **新しいマシン (app-VM) が `Pending` のまま止まっている。** 変換用マシンがシャットダウンされていません。クォータの 8Gi を占有しているため、新しいマシンに割り当てる分が足りません。それとそのディスクを削除してください:
  ```bash
  kubectl delete vminstance convert --namespace tenant-workshopXX
  kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
  ```

• **イメージのアップロード時に `mc` が `Insufficient permissions` と表示する。** `convert.sh` の `BUCKET` フィールドに、本物の `bucketName`(長い `bucket-...-...`)ではなく `my-images` が入っています。ダッシュボードにあるバケットの Secret から `bucketName` を取得して、それを入れてください。

• **ディスクが Terminating 状態のまま止まっている。** 多くの場合、ディスクサイズがイメージより小さいのが原因です。ubuntu-20.04 では少なくとも 25Gi が必要です。

• **何をしてもダメ。** ここに書いてください、一緒に解決しましょう。これは仕事の当たり前の一部であって、恥ずかしがるようなことではありません。実際の移行でも同じことが起きます。ただ、それが夜中の 3 時だというだけです。
