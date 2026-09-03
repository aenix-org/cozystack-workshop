# ワークショップのチャットメッセージ — bastion 経由の進め方

1ファイルにつき1メッセージです。まとめて送らず、実習の進行に合わせて投稿してください。

このセットは、**共有の bastion（VM）経由で作業する**参加者向けです。
ツールとクラスターへのアクセスはすでに bastion 上に用意されており、テナント番号もあらかじめファイルに埋め込まれ、
アプリケーションはドメイン名で確認します。自分のノートPCから作業する場合のセットは
[`../../laptop/chat/`](../../laptop/chat/) にあります。

メッセージの番号はノートPC版と通しになっています（そのため欠番があります。ツールのインストールに関する
投稿はここでは不要だからです）。

| # | メッセージ | ファイル |
|---|---|---|
| 1 | 私たちがこれから実際に行うこと | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | ちょっとした用語集：あなたの側での呼び方と、ここでの呼び方 | [`02-glossary.md`](02-glossary.md) |
| 3 | 始める前に：必要になるもの | [`03-prerequisites.md`](03-prerequisites.md) |
| 8 | bastion にログインする | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 10 | 教材はすでに bastion 上にあります | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | ファイルマップ：何がどこにあり、どこで実行されるか | [`11-file-map.md`](11-file-map.md) |
| 12 | フェーズ1. vSphere からイメージを取り出す | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | 詳しく見る：01-bucket.yaml の中身 | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | ステップ1：自分専用のストレージ | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | 詳しく見る：02-conversion-vm.yaml の中身 | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | ステップ2：変換マシン | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | 詳しく見る：convert.sh は何をするか | [`17-convert-script.md`](17-convert-script.md) |
| 18 | ステップ3：イメージの変換 | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | フェーズ2. 新しい場所でマシンを起動する | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | 詳しく見る：03-app-vm.yaml の中身 | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | ステップ4：あなたの仮想マシン | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | フェーズ3. 動物園を捨てる | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | 詳しく見る：04-managed.yaml の中身 | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | ステップ5：カタログからデータベースとキューを | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | ステップ6：マシン内部のネットワークを直す | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | 最初の確認：起動を試みてエラーに遭遇する | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | ステップ7：アプリケーションをマネージドサービスに向ける | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | ステップ8：アプリケーションがまだクラッシュする理由 | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | ステップ8：クライアントをインストールしてスキーマを適用する | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | ステップ9：チェーン全体を検証する | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | うまく動かないとき | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | ワークショップのあとで | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
