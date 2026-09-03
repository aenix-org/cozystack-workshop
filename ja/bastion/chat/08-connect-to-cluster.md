## 8. bastion へのログイン

**ログインは一度きり、それだけでもうクラスターの中**

📍 **場所:** ダッシュボードはブラウザで開きます。それ以外はすべて bastion 上で SSH 越しに行います。

**あなたの認証情報**（ログインとパスワードは3か所すべてで同じです）:
```
dashboard: https://dashboard.workshop.aenix.io
bastion:   ssh workshopXX@<bastion-address>
login:     workshopXX      ← あなたの番号、直接お伝えします
password:  ...             ← 直接お伝えします
```

bastion にログインします。パスワードはダッシュボードと同じで、**SSH鍵は不要です**:

```bash
ssh workshopXX@<bastion-address>
```

中に入れば、クラスターへのアクセスはすでに設定済みです。kubeconfig は `~/.kube/config` にあり、`kubectl`
はすぐにあなたのテナントを認識します。**このときブラウザは開きません** — クラスターへのログインは
Keycloak を介さず、トークンで行われます。確認しましょう:

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

最初のコマンドは `tenant-workshopXX` を表示し、2つ目は `No resources found` と返します。これが
正しい応答です。マシンはまだありませんが、クラスターはあなたを認識しています。

⚠️ `kubectl get vm` と `kubectl get vmi` は動きません。あなたのアカウントでは `vminstance` タイプが
利用可能です。これは意図的な仕様です。

⚠️ ブラウザのダッシュボード（マウス操作の手順用）は同じログインとパスワードを使います。ただし、
ダッシュボードから取得できる kubeconfig（`Info → Secrets → kubeconfig-tenant-workshopXX`）を bastion に
ダウンロードする**必要はありません**。そちらはブラウザ経由のログイン用であり、bastion にはそれなしで
動く用意済みのものがすでに置かれています。
