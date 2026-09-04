#!/usr/bin/env bash
# ラボ7のチェック: キャッシュは実際に高速化し、それが数字に表れる。
#
# ここでの主なチェックは構造的ではなく振る舞いのチェックである。スクリプトは未使用の
# 識別子を選び、それを2回リクエストして観察する: 1回目は数百ミリ秒のミス、
# 2回目は数ミリ秒のヒットになるはず。正しい環境変数を持つマニフェストでも、
# キャッシュが実際に応答していなければこのチェックは通らない。
#
# 2つのクラスタ: KUBECONFIG はあなたの lab クラスタ、COZY_KUBECONFIG は managed Redis
# サービスが動く Cozystack 管理クラスタ。

# LAB_NAME と LAB_TITLE はレポートのヘッダーに入る。続いて共通のチェックライブラリを
# 読み込む: そこから ok / warn / fail / evidence / finish、そして最も重要な
# in_cluster_curl が使える — これはクラスタ内部で curl を持つ使い捨ての Pod を起動する。
# ノートPCからではなく内部から: lab のサービスは外部に公開されておらず、passes-api は
# クラスタ内からのみ名前で到達できる。need_kubeconfig と need_tenant は、アクセスや
# テナント番号が設定されていない場合にスクリプトを事前に止める — さもないとすべての
# チェックが一斉に失敗し、レポートから原因が分からなくなる。
LAB_NAME="07-redis"
LAB_TITLE="ラボ7 · 遅いバックエンドの前段キャッシュ"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# チェック全体が参照する名前とアドレスは1か所にまとめてある: スクリプトのテキストを
# 探し回る必要はない。テナントアクセスがデフォルト以外の場所にある場合は、
# COZY_KUBECONFIG を外部から上書きできる。
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# スクリプト全体で使う2つの短縮関数: kget は lab クラスタ（KUBECONFIG のもの）に、
# cozy は Cozystack 管理クラスタにアクセスする。エラーメッセージは意図的に抑制している:
# ここでオブジェクトが無いのは通常の状況で、スクリプトが kubectl の他人の文言ではなく
# 自分の言葉とヒントで説明する。
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# JSON からフィールドを取り出す。jq なしで: 素の macOS には jq が無いが、python3 は
# チェックライブラリの他の部分が動くところならどこにでもある。
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- 管理クラスタ上の managed Redis サービス ----------------------------------
# Redis はあなたの lab クラスタではなく、管理クラスタ上のテナントに存在する: これは
# managed サービスで、プラットフォームが自分で稼働を維持する。テナント内の権限は
# 人によって異なるため、アクセス拒否も kubeconfig の欠如もラボを失敗させない —
# キャッシュの動作は以下でライブリクエストにより直接チェックする、それが本当の証拠だ。
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "テナント kubeconfig ${COZY_KUBECONFIG} が見つかりません — Redis の状態は未チェックです" \
       "パスを指定してください: export COZY_KUBECONFIG=~/.kube/workshop"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "テナント ${TENANT_NS} の Redis アプリケーションを表示できませんでした" \
         "テナントのロールがこのコマンドを許可していない可能性があります — これはラボのエラーではありません; キャッシュの動作は以下で直接チェックします"
  elif [ -z "$REDIS_LIST" ]; then
    fail "テナント ${TENANT_NS} に Redis アプリケーションが1つもありません" \
         "ダッシュボードで作成してください: アプリケーションを作成 -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "managed Redis «${R_NAME}» の準備ができました、データのコピー数: ${R_REPLICAS:-デフォルト}"
    else
      warn "Redis «${R_NAME}» は存在しますが、準備完了を報告していません" \
           "ダッシュボードでその状態を確認してください; 起動には3〜5分かかります"
    fi
    evidence "テナント内の Redis" "$REDIS_LIST"
  fi
fi

# --- 遅いディレクトリが所定の場所にあり、実際に遅い --------------------------
# このチェックが無いと「前後」の比較は意味を持たない: ディレクトリが即座に
# 応答するなら、高速化するものは何もなく、キャッシュが測るものも無い。
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "ディレクトリ ${HR} が動作していません" \
       "hr-legacy.yaml を適用し、kubectl describe pod -l app=hr-legacy を確認してください"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "ディレクトリは ${HR_MS} ms で応答します — 高速化する余地があります"
    evidence "ディレクトリのレイテンシ" "/employee リクエストあたり ${HR_MS} ms"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "ディレクトリ ${HR} がリクエストに応答しませんでした" \
         "kubectl logs -l app=hr-legacy を確認してください"
  else
    warn "ディレクトリは ${HR_MS} ms で応答しますが、測定するには速すぎます" \
         "hr-legacy.yaml に MODE=hr と HR_DELAY=800ms が設定されているか確認してください"
  fi
fi

# --- アプリケーションがキャッシュ用に設定されている -------------------------
# コンテナの環境を jsonpath ではなく python で解析する: ネストしたリストに対する
# jsonpath フィルタは kubectl のバージョンによって挙動が異なり、チェックが誰にとっても
# 同じように動くことを重視するため。
DEPLOY_JSON="$(kget deployment "$APP" -o json)"
readenv() {
  printf '%s' "$DEPLOY_JSON" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read())
    env = d["spec"]["template"]["spec"]["containers"][0].get("env", [])
except Exception:
    raise SystemExit
want = sys.argv[1]
if want == "--names":
    print("\n".join(e.get("name","") for e in env))
else:
    for e in env:
        if e.get("name") == want:
            print(e.get("value", ""))
            break' "$1" 2>/dev/null
}

ENVS="$(readenv --names)"
REDIS_ADDR="$(readenv REDIS_ADDR)"
TTL="$(readenv CACHE_TTL)"

# 不満は順に処理される — 最も一般的なものから最も具体的なものへ: アプリケーションが無い、
# 変数が無い、アドレスの代わりにプレースホルダが残っている。ここでの順序は装飾ではない:
# さもないと、参加者はサービス自体がまだデプロイされていない時点で「Redis のアドレスを
# 入力してください」という助言を受け取り、誤った場所でエラーを探すことになる。
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "lab クラスタにアプリケーション ${APP} がありません" \
       "自分の Harbor のアドレスを入力して passes-api.yaml を適用してください"
elif [ -z "$REDIS_ADDR" ]; then
  fail "${APP} に REDIS_ADDR 変数が設定されていません — キャッシュは無効です" \
       "パッチを適用してください: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "パッチにプレースホルダのアドレス REDIS-ADDR が残っています" \
       "自分の Redis のアドレスを入力してください、例: rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "アプリケーションはアドレス ${REDIS_ADDR} のキャッシュ用に設定されています、エントリの有効期間 ${TTL:-デフォルト} 秒"
fi

# 変数名の有無だけを見ており、その値はどこでも読んだり出力したりしない。
# ラボのレポートは互いに転送されチケットに添付される — そこに入り込んだパスワードは
# 永遠にそこに残る。
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "Redis のパスワードがアプリケーションに届きます (値: <非表示>)"
else
  fail "${APP} に REDIS_PASSWORD 変数が設定されていません" \
       "Redis は認証を必要とします; redis-password シークレットを作成し cache-patch.yaml を適用してください"
fi

# シークレットが無いのは失敗ではなく警告: パスワードは別の方法でも Pod に届けられる。
# ここでチェックする性質は別だ — マニフェストには値ではなく参照が入っている。
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "Redis のパスワードを持つ redis-password シークレットが存在します"
else
  warn "クラスタに redis-password シークレットがありません" \
       "作成してください: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- 主なチェック: キャッシュが実際に高速化する ----------------------------
# 1回目のリクエストが確実にミスになるよう、あえて新しい識別子を選ぶ。
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "サービス ${APP} が期待した JSON を返しませんでした" \
       "kubectl logs -l app=passes-api を確認してください; イメージがこのラボの app/ からビルドされているか確認してください (タグ v2)"
  evidence "サービスの応答内容" "1回目のリクエスト: ${R1:-空}
2回目のリクエスト: ${R2:-空}"
elif [ "$MODE" != "redis" ]; then
  fail "アプリケーションはキャッシュが無効だと報告しています (cache: ${MODE})" \
       "REDIS_ADDR 変数が稼働中の Pod に届いていません — kubectl rollout status deployment/${APP} を確認してください"
elif [ "$C1" = "True" ]; then
  warn "1回目のリクエストが既にキャッシュから返りました — 比較対象がありません" \
       "識別子の衝突は起こりにくいですが; チェックをもう一度実行してください"
elif [ "$C2" != "True" ]; then
  fail "同じ識別子での2回目のリクエストが再びキャッシュにヒットしませんでした" \
       "アプリケーションが Redis に書き込めません: kubectl logs -l app=passes-api を確認してください、通常はそこに NOAUTH かタイムアウトがあります"
  evidence "サービスの応答" "1回目:  ${R1}
2回目: ${R2}"
else
  ok "キャッシュが動作しています: ミス ${T1} ms、ヒット ${T2} ms"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "1000倍以上")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "稼働中サービスでの測定" "識別子: ${PROBE_ID}
1回目のリクエスト (ミス):   ${T1} ms
2回目のリクエスト (ヒット): ${T2} ms
高速化: 約 ${SPEEDUP} 倍
エントリの有効期間: ${TTL:-デフォルト} 秒"

  # 厳密な部分: ヒットはミスより1桁速くなければならない。さもないと
  # 「キャッシュが動作している」はキーが書き込まれたことだけを意味し、利益は無い。
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "利益は測定可能です: ヒットはミスより約 ${SPEEDUP} 倍速い"
  else
    warn "キャッシュヒットが目立った利益をもたらしません (${T1} ms 対 ${T2} ms)" \
         "ディレクトリが実際に遅いこと、そして Redis が同じ Pod 上に無いことを確認してください"
  fi
fi

# --- サービスのいくつのコピーが1つのキャッシュを共有するか -------------------
# キャッシュはすべてのコピーで共有される — これはレポートで見ておく価値がある:
# ヒットはミスとは別の Pod から来たかもしれず、それは正しい。
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "稼働中のサービスコピー: ${API_PODS} (それらはキャッシュを共有します)"
  evidence "サービスのコピー" "$(kget pods -l app=passes-api -o wide)"
else
  fail "${APP} の稼働中コピーが1つもありません" \
       "kubectl describe pod -l app=passes-api を確認してください"
fi

finish
