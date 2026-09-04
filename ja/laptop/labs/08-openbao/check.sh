#!/usr/bin/env bash
# ラボ8のチェック: パスワードはマニフェストから OpenBao へ移され、ルールに従って存在する。
#
# 「オブジェクトが作成された」ではなく、本質を確認する: 保管庫が開封され、シークレットが
# トークンで読み取れ、バージョンが2つ以上あり(つまりローテーションが実際に行われた)、監査が
# 有効で、適用済みのアプリケーション・マニフェストに平文パスワードが無いこと。
#
# シークレットは一切レポートに載らない。値はどこにも出力されない。
#
# スクリプトは curl 入りの使い捨てポッドを立ち上げるので、実行には約1分かかる。

# LAB_NAME と LAB_TITLE はレポートのヘッダーに入る。以下では共通のチェック・ライブラリを
# 読み込む: そこから ok / warn / fail / evidence / finish と、クラスター内で使い捨てポッドを
# 実行する関数を取り込む。need_kubeconfig と need_tenant は、アクセスやテナント番号が
# 指定されていない場合にスクリプトを早めに止める: さもないと全部が一度に失敗し、
# レポートから原因を突き止められなくなる。
LAB_NAME="08-openbao"
LAB_TITLE="ラボ8 · シークレットをマニフェストに置かない"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- どこを見るか ---------------------------------------------------------
# 参加者は COZY_TENANT を `workshop07` と指定するが、namespace は
# `tenant-workshop07` という名前になる。両方の書き方を受け付ける: ここは間違えやすく、
# エラーメッセージも分かりにくくなる(「サービスが応答しない」)。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 何をどこで探すか。BAO_APP はテナント内の OpenBao アプリケーションの名前で、
# それは保管庫の内部アドレスの一部になる: アプリケーションに別の名前を付けたなら、
# チェックを BAO_APP=名前 ./check.sh として実行する。SECRET_PATH は保管庫内のパスで、
# ラボはそこにデータベースのパスワードを置く。
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "保管庫のアドレス" "$BAO_URL"

# 標準入力の JSON から、キーの連なりで値を取り出す。
# パスが無いか JSON でない場合は 1 を返す — こうして呼び出し側は
# 「そのキーが無い」と「空の値」を区別できる。
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


# OpenBao へのリクエスト。トークンは一時的な Secret から環境変数として渡し、
# 引数のヘッダーとしては渡さない: ポッドの引数は `get pods` 権限のある誰にでも見え、
# etcd に保存され、監査ログに流れる。ここでは保管庫の root トークン — このラボ全体が
# その対策として書かれている、まさにその漏洩だ。
#
# 定義は最初の呼び出しより前に置く: これが else ブランチの中にあったとき、
# 一番最初のチェックが存在しない関数を呼び、ラボは決して合格できなかった。
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. 保管庫が応答する -------------------------------------------------
# 最初のリクエストが二つの問いに一度に答える: アプリケーションは立ち上がったか、そして
# テナント番号は正しいか。封印状態を尋ねる — これは OpenBao がトークン無しで応答する
# 唯一のエンドポイントだ。この後に応答が空なら「接続なし」を意味し、内容に関する
# すべてのチェックは意味を失う。
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao が ${BAO_URL} で応答しない" \
       "COZY_TENANT のテナント番号とアプリケーション名を確認してください(デフォルトは 'secrets'; 違う場合は BAO_APP=名前 ./check.sh); ダッシュボードでアプリケーションが準備完了状態である必要があります"
else
  ok "OpenBao がテナントの内部アドレスで応答している"
fi

# --- 2. 初期化済み ----------------------------------------------------
# 初期化は一度きりの操作で、そこで保管庫はマスターキーと最初のトークンを自分で作る。
# それが行われるまで中には何も無い: シークレットも、それを置く場所も無い。
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "保管庫は初期化されている"
elif [ -n "$SEAL" ]; then
  fail "保管庫が初期化されていない" \
       "実行してください: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 そして出力を保存してください"
fi

# --- 3. 開封済み --------------------------------------------------------
# 封印された保管庫はポッド再起動後の通常の状態だ: データはディスク上にあるが、
# unseal キーを入力するまでそれを読む手段が無い。だからこそオブジェクトの存在ではなく
# 振る舞いを確認せよという要求になる: 「アプリケーションは準備完了」と「シークレットが提供される」は
# 二つの別の主張であり、後者は前者から導かれない。
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "保管庫は開封されリクエストに応じている"
  evidence "保管庫の状態" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "保管庫が封印されている — どのリクエストにも 503 の拒否で応答する" \
       "実行してください: kubectl exec bao-workbench -- bao operator unseal <あなたの unseal キー>"
  evidence "保管庫の状態" "$SEAL"
fi

# --- 4. シークレットが所定の場所にあり読み取れる -----------------------------------------
# 次にトークンが必要だ。それが無いと確認するものが無いが、黙って飛ばすわけにもいかない:
# 読み手には何が足りないのかが見えなければならない。
if [ -z "$SEAL" ]; then
  # 接続なし — 内容の確認は無意味。同じ原因を持つ4つの失敗でレポートを埋めないように
  # 黙っておく。原因は上で既に名指ししてある。
  warn "保管庫の内容は未確認: OpenBao への接続がない" \
       "接続を解決してから、スクリプトを再度実行してください"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "BAO_TOKEN 変数が未設定のため、保管庫の内容は未確認" \
       "export BAO_TOKEN='保管庫を初めて開封したときに表示された root トークン' を設定し、スクリプトを再度実行してください"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "シークレット secret/${SECRET_PATH} はトークンで読み取れ、password フィールドは空でない"
    # レポートには値ではなくバージョン番号を入れる。
    evidence "シークレット" "パス: secret/${SECRET_PATH}
password フィールド: あり(値は非表示)
現在のバージョン: ${DATA_VERSION:-不明}"
  else
    fail "secret/${SECRET_PATH} のパスに password フィールドが無い" \
         "そこに置いてください: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; エンジンがまだ有効でなければ — bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. ローテーションが実際に行われた --------------------------------------
  # シークレットのバージョンが一つだけなら、置いて忘れたということだ。ローテーションこそ
  # 保管庫を用意する理由そのもの: マニフェスト中を探し回るのではなく、一箇所でパスワードを
  # 変える。約束ではなくバージョンを数える: その数は保管庫が自分で記録している。
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "シークレットは変更された: バージョン ${CUR_VER}、つまりローテーションは言葉だけでなく実際に行われた"
    evidence "シークレットのバージョン履歴" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "シークレットのバージョンが一つだけ — ローテーションが行われていない" \
         "パスワードを変えてください: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<新しい値> そしてアプリケーションを再起動してください"
  fi

  # --- 6. ポリシーは狭く、「何でもあり」ではない ---------------------------------
  # ポリシーはまさに「トークンを手に入れた者に何ができるか」への答えだ。だから
  # その存在の事実ではなく内容を見る: 保管庫全体ではなく特定のパスに対して与えられているか、
  # そして読み取り専用か。
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "ポリシー passes-read が存在する"
    evidence "ポリシー passes-read" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "ポリシーは保管庫全体ではなく特定のパスに対して与えられている"
    else
      warn "ポリシーはあるが、その中にパス secret/data/${SECRET_PATH} が見当たらない" \
           "ポリシーに data プレフィックスが指定されているか確認してください: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "ポリシーが読み取り以外も許可している" \
           "アプリケーションには read で十分; 余分な権限は削除すべきです"
    fi
  else
    fail "ポリシー passes-read が見つからない" \
         "作成してください: kubectl exec -i bao-workbench -- bao policy write passes-read - < あなたのポリシーファイル(ポリシーの解説は README にあります)"
  fi

  # --- 7. 監査が有効 ----------------------------------------------------
  # 監査ログが無ければ「誰がいつこのシークレットを読んだか」に答える手段が無い — そしてそれは
  # インシデント後に最初に尋ねられる問いだ。接続された監査デバイスを数える: 少なくとも
  # 一つは無ければならない。
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
    ok "監査ログが有効(デバイス数: ${AUD_COUNT})"
    evidence "監査デバイス" "$AUD"
  else
    fail "監査ログが有効でない — 誰がシークレットを読んだかに答える手段が無くなる" \
         "有効にしてください: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. ラボ・クラスター内のアプリケーション ---------------------------------
# ここまでは管理クラスター上の保管庫を確認してきた。次はあなたの lab クラスターで、
# そこにアプリケーション自体が存在する。ここで重要なのは Deployment が作成された事実ではなく、
# 準備完了レプリカの有無だ: パスワードを取得できなかった init コンテナはポッドを立ち上げさせず、
# まさにその状態を「すべて良好」と区別しなければならない。
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "ラボ・クラスターにアプリケーション ${APP_DEPLOY} が無い" \
       "適用してください: kubectl apply -f secrets-demo.yaml(自分のテナント番号を差し込むのを忘れずに)"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "アプリケーション ${APP_DEPLOY} が稼働中(準備完了レプリカ: ${READY})"
  else
    fail "アプリケーション ${APP_DEPLOY} はあるが、準備完了のレプリカが一つも無い" \
         "kubectl describe deploy/${APP_DEPLOY} と kubectl logs deploy/${APP_DEPLOY} -c fetch-secret を見てください — たいてい init コンテナが保管庫に到達できなかったか、トークンで拒否されています"
  fi

  # --- 9. マニフェストに平文パスワードが無い -------------------------
  # ディスク上のファイルではなく適用済みのオブジェクトを見る: 何が適用されたか分からない。
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
            found.append("%s / env %s は参照ではなく値で設定されている" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "アプリケーションのマニフェストに、値で設定されたパスワード変数は無い"
  else
    fail "アプリケーションのマニフェストに機微な値が平文のまま残っている" \
         "取り除いてください: 値は保管庫から来るべきで、マニフェストには参照だけを置きます。secrets-demo.yaml を参照"
    evidence "マニフェストで見つかったもの" "$LEAKS"
  fi

  # --- 10. アプリケーションが実際にシークレットを受け取った ------------------------
  # 最後の証拠はオブジェクトの記述ではなくログから取る。マニフェストは完璧でも、
  # パスワードがポッドに届かないことはある。二つのことを同時に見る:
  # init コンテナが保管庫へ行ったと報告し、アプリケーションがフィンガープリントを出力する —
  # つまり、受け取ったパスワードで実際に動いているということだ。
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "init コンテナが保管庫からシークレットを取得した"
    evidence "init コンテナのログ" "$INIT_LOG"
  else
    fail "init コンテナが保管庫からシークレットを取得した形跡が見えない" \
         "kubectl logs deploy/${APP_DEPLOY} -c fetch-secret を確認してください; そのコンテナが無ければ — 古いマニフェストが適用されています"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "アプリケーションは受け取ったパスワードで動いている(ログには値ではなくフィンガープリントが書かれる)"
    evidence "アプリケーションのログ" "$APP_LOG"
  else
    fail "アプリケーションのログにパスワードのフィンガープリントが無い" \
         "kubectl logs deploy/${APP_DEPLOY} -c app を確認してください — コンテナが起動できなかった可能性があります"
  fi
fi

# --- 11. 素朴なシークレットが取り除かれている ----------------------------------------
# 「削除済み」と数えるのはラボを実際に行った場合だけだ: まっさらなクラスターにはシークレットが
# もともと存在せず、行われていない後片付けで参加者を褒めてしまうことになる。
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "クラスターに素朴な段階のシークレット passes-db が残っている" \
       "それはもう不要で、古いパスワードを含んでいる: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "素朴なシークレット passes-db は削除済み"
fi

finish
