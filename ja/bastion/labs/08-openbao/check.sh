#!/usr/bin/env bash
# ラボ8のチェック: パスワードはマニフェストから OpenBao へ移され、ルールに従って管理される。
#
# 「オブジェクトが作成された」かではなく、本質を確認する。すなわち、ボールトが unseal され、
# シークレットがトークンで読み取れ、バージョンが2つ以上あり（=ローテーションが実際に行われた）、
# 監査が有効で、適用されたアプリのマニフェストに平文のパスワードが無いこと。
#
# シークレットは一切レポートに載らない。値はどこにも出力されない。
#
# スクリプトは curl 入りの使い捨て Pod を立ち上げるため、実行に約1分かかる。

# LAB_NAME と LAB_TITLE はレポートのヘッダーに入る。以下では共通チェックライブラリを読み込む。
# そこから ok / warn / fail / evidence / finish と、クラスタ内で使い捨て Pod を立ち上げる関数を
# 取得する。need_kubeconfig と need_tenant は、アクセスやテナント番号が未設定の場合にスクリプトを
# 早めに止める。さもないと一度に全部失敗し、レポートから原因が分からなくなる。
LAB_NAME="08-openbao"
LAB_TITLE="ラボ8 · シークレットはマニフェストの中に置かない"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- どこを見るか -----------------------------------------------------------
# 参加者は COZY_TENANT を `workshop07` のように指定するが、namespace は
# `tenant-workshop07` という名前になる。両方の書き方を受け付ける。ここでは間違えやすく、
# エラーメッセージも分かりにくくなる（「サービスが応答しない」）。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 何をどこで探すか。BAO_APP はテナント内の OpenBao アプリの名前で、ボールトの内部アドレスの
# 一部になる。アプリを別名にした場合は BAO_APP=名前 ./check.sh のように実行する。
# SECRET_PATH はボールト内のパスで、ラボはそこにデータベースのパスワードを置く。
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "ボールトのアドレス" "$BAO_URL"

# 標準入力の JSON から、キーの連鎖で値を取り出す。
# パスが存在しない、または JSON でない場合は 1 を返す。これにより呼び出し側は
# 「キーが無い」と「値が空」を区別できる。
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for k in sys.argv[1:]:
    try:
        d = d[int(k)] if isinstance(d, list) else d[k]
    except Exception:
        sys.exit(1)
print("" if d is None else d)
' "$@" 2>/dev/null
}


# OpenBao へのリクエスト。トークンは一時的な Secret から環境変数として渡し、引数のヘッダーとしては
# 渡さない。Pod の引数は `get pods` できる誰にでも見え、etcd に保存され、監査ログにも入るからだ。
# ここではボールトの root トークンであり、このラボ全体が対策しようとしている、まさにその漏洩だ。
#
# 定義は最初の呼び出しより前に置く。以前これが else ブランチの中にあったとき、いちばん最初の
# チェックが存在しない関数を呼び、ラボは決して合格しなかった。
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. ボールトが応答する -------------------------------------------------
# 最初のリクエストで2つの問いに同時に答える。アプリが起動したか、そしてテナント番号が正しいか。
# seal 状態を問い合わせる。これはトークン無しで OpenBao が返す唯一のエンドポイントだ。この先で
# 応答が空なら「接続なし」を意味し、内容に関するすべてのチェックは意味を失う。
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao が ${BAO_URL} で応答しません" \
       "COZY_TENANT のテナント番号とアプリ名（デフォルトは 'secrets'。異なる場合は BAO_APP=名前 ./check.sh）を確認してください。ダッシュボードでアプリが ready 状態になっている必要があります"
else
  ok "OpenBao がテナントの内部アドレスで応答しています"
fi

# --- 2. 初期化済み ---------------------------------------------------------
# 初期化は一度きりの操作で、ボールトは自身のマスターキーと最初のトークンを作成する。
# これが済むまで中には何も無い。シークレットも、それを置く場所も無い。
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "ボールトは初期化されています"
elif [ -n "$SEAL" ]; then
  fail "ボールトが初期化されていません" \
       "実行してください: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 して出力を保存してください"
fi

# --- 3. unseal 済み --------------------------------------------------------
# seal されたボールトは Pod 再起動後の通常の状態だ。データはディスク上にあるが、unseal キーを
# 入力するまでそれを読む手段が無い。だからオブジェクトの有無ではなく振る舞いを確認する必要がある。
# 「アプリが ready」と「シークレットが提供される」は別々の主張であり、後者は前者から導かれない。
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "ボールトは unseal され、リクエストを処理しています"
  evidence "ボールトの状態" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "ボールトが seal されています — あらゆるリクエストに 503 で拒否を返します" \
       "実行してください: kubectl exec bao-workbench -- bao operator unseal <あなたの-unseal-キー>"
  evidence "ボールトの状態" "$SEAL"
fi

# --- 4. シークレットが所定の場所にあり読み取れる ----------------------------
# 次はトークンが必要だ。それが無ければ確認しようがないが、黙って飛ばすわけにもいかない。
# 読み手には何が足りないのかが見えなければならない。
if [ -z "$SEAL" ]; then
  # 接続なし — 内容の確認は無意味だ。上で述べた同じ原因による4つの失敗でレポートを
  # 埋め尽くさないよう、黙っておく。
  warn "ボールトの内容は未確認: OpenBao への接続がありません" \
       "接続を解決してから、スクリプトを再実行してください"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "BAO_TOKEN 変数が未設定のため、ボールトの内容は未確認です" \
       "export BAO_TOKEN='ボールトの最初の unseal 時に表示された root トークン' を実行し、スクリプトを再実行してください"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "シークレット secret/${SECRET_PATH} はトークンで読み取れ、password フィールドは空ではありません"
    # レポートには値ではなくバージョン番号を載せる。
    evidence "シークレット" "パス: secret/${SECRET_PATH}
password フィールド: あり（値は非表示）
現在のバージョン: ${DATA_VERSION:-不明}"
  else
    fail "secret/${SECRET_PATH} に password フィールドがありません" \
         "配置してください: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; エンジンがまだ有効でない場合は — bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. ローテーションが実際に行われた ----------------------------------
  # シークレットのバージョンが1つだけなら、それは一度設定して忘れたということだ。ローテーションこそ
  # ボールトを用意する目的そのものだ。マニフェスト中を探し回るのではなく、一箇所でパスワードを変える。
  # 約束ではなくバージョンを数える。その数はボールト自身が管理している。
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "シークレットは変更されました: ${CUR_VER} バージョン、つまりローテーションは口先だけでなく実際に行われました"
    evidence "シークレットのバージョン履歴" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "シークレットのバージョンが1つだけです — ローテーションが行われていません" \
         "パスワードを変えてください: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<新しい値> してアプリを再起動してください"
  fi

  # --- 6. ポリシーは「何でもあり」ではなく限定的 ---------------------------
  # ポリシーとは「トークンを入手した者に何ができるか」という問いへの答えだ。だから存在するという
  # 事実ではなく、その内容を見る。ボールト全体ではなく特定のパスに対して付与されているか、そして
  # 読み取り専用か。
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "passes-read ポリシーが存在します"
    evidence "passes-read ポリシー" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "ポリシーはボールト全体ではなく特定のパスに付与されています"
    else
      warn "ポリシーはあるが、その中に secret/data/${SECRET_PATH} のパスが見当たりません" \
           "ポリシーに data プレフィックスが指定されているか確認してください: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "ポリシーが読み取り以外も許可しています" \
           "アプリには read で十分です。余分な権限は削除すべきです"
    fi
  else
    fail "passes-read ポリシーが見つかりません" \
         "作成してください: kubectl exec -i bao-workbench -- bao policy write passes-read - < あなたのポリシーファイル（ポリシーの解説は README にあります）"
  fi

  # --- 7. 監査が有効 -------------------------------------------------------
  # 監査ログが無ければ「誰がいつこのシークレットを読んだか」に答える手段が無い。そしてそれは
  # インシデント後に最初に問われることだ。接続された監査デバイスを数える。少なくとも1つは
  # 必要だ。
  AUD="$(bao_get "/v1/sys/audit")"
  AUD_COUNT="$(printf '%s' "$AUD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
data = d.get("data", d)
print(len([k for k in data if isinstance(data.get(k), dict)]))
' 2>/dev/null)"
  case "$AUD_COUNT" in
    ''|*[!0-9]*) AUD_COUNT=0 ;;
  esac
  if [ "$AUD_COUNT" -ge 1 ]; then
    ok "監査ログが有効です（デバイス数: ${AUD_COUNT}）"
    evidence "監査デバイス" "$AUD"
  else
    fail "監査ログが有効になっていません — 誰がシークレットを読んだか答える手段がありません" \
         "有効化してください: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. ラボクラスタ内のアプリ ---------------------------------------------
# ここまでは管理クラスタ上のボールトを確認してきた。次はアプリ本体が動くあなたの lab クラスタだ。
# ここで重要なのは Deployment が作成されたという事実ではなく、ready なレプリカがあることだ。
# パスワードを取得できなかった init コンテナは Pod を起動させず、まさにその状態を「万事良好」と
# 区別しなければならない。
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "ラボクラスタにアプリ ${APP_DEPLOY} がありません" \
       "適用してください: kubectl apply -f secrets-demo.yaml（自分のテナント番号を差し込むのを忘れずに）"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "アプリ ${APP_DEPLOY} が稼働しています（ready なレプリカ数: ${READY}）"
  else
    fail "アプリ ${APP_DEPLOY} はあるが、ready なレプリカが1つもありません" \
         "kubectl describe deploy/${APP_DEPLOY} と kubectl logs deploy/${APP_DEPLOY} -c fetch-secret を見てください — 通常は init コンテナがボールトに到達できなかったか、トークンで拒否されています"
  fi

  # --- 9. マニフェストに平文のパスワードが無い -----------------------------
  # ディスク上のファイルではなく適用済みのオブジェクトを見る。実際には何でも適用できてしまうからだ。
  LEAKS="$(kubectl get deploy "$APP_DEPLOY" -o json 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
suspicious = re.compile(r"(?i)pass|secret|token|key|cred")
spec = d.get("spec", {}).get("template", {}).get("spec", {})
found = []
for c in list(spec.get("initContainers", [])) + list(spec.get("containers", [])):
    for e in c.get("env", []):
        if "value" in e and suspicious.search(e.get("name", "")):
            found.append("%s / env %s は参照ではなく値で設定されています" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "アプリのマニフェストに、値で設定されたパスワード変数はありません"
  else
    fail "アプリのマニフェストに機密の値が平文のまま残っています" \
         "削除してください: 値はボールトから来るべきで、マニフェストには参照だけを置きます。secrets-demo.yaml を参照"
    evidence "マニフェストで見つかったもの" "$LEAKS"
  fi

  # --- 10. アプリが実際にシークレットを受け取った --------------------------
  # 最後の証拠はオブジェクトの記述ではなくログから取る。マニフェストは完璧でも、パスワードが
  # Pod に届かないことはある。2つのことを同時に見る。init コンテナがボールトへ行ったと報告し、
  # アプリがフィンガープリントを出力していること。つまり受け取ったパスワードで実際に動いている。
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "init コンテナがボールトからシークレットを取得しました"
    evidence "init コンテナのログ" "$INIT_LOG"
  else
    fail "init コンテナがボールトからシークレットを取得した形跡がありません" \
         "kubectl logs deploy/${APP_DEPLOY} -c fetch-secret を確認してください。そのコンテナが無ければ — 古いマニフェストが適用されています"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "アプリは受け取ったパスワードで動作しています（ログには値ではなくフィンガープリントが書かれます）"
    evidence "アプリのログ" "$APP_LOG"
  else
    fail "アプリのログにパスワードのフィンガープリントがありません" \
         "kubectl logs deploy/${APP_DEPLOY} -c app を確認してください — コンテナが起動しなかった可能性があります"
  fi
fi

# --- 11. 素朴なシークレットが削除されている --------------------------------
# 「削除済み」と数えるのはラボを実際に行った場合だけだ。まっさらなクラスタではシークレットは
# 一度も存在せず、行われてもいない後片付けをレポートが参加者に褒めてしまう。
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "クラスタに素朴な段階の passes-db シークレットが残っています" \
       "もう不要で、古いパスワードを保持しています: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "素朴な passes-db シークレットは削除されました"
fi

finish
