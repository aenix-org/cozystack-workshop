#!/usr/bin/env bash
# ラボ7のチェック: キャッシュが実際に速度を上げ、それが数値に表れる。
#
# ここでの主なチェックは構造的ではなく挙動的なものだ。スクリプト自身が未使用の
# 識別子を取り、それを2回リクエストして観察する: 1回目は数百ミリ秒のミスに、
# 2回目は1桁ミリ秒のヒットになるはず。正しい環境変数を持つマニフェストでも、
# キャッシュが実際に応答しなければこのチェックには通らない。
#
# 2つのクラスター: KUBECONFIG はあなたの lab クラスター、COZY_KUBECONFIG は
# managed な Redis サービスが動く Cozystack 管理クラスター。

# LAB_NAME と LAB_TITLE はレポートのヘッダーに入る。次に共通のチェックライブラリが
# 読み込まれる: そこから ok / warn / fail / evidence / finish が来て、とりわけ
# in_cluster_curl も来る — これはクラスター内部に curl 入りの使い捨て Pod を立てる。
# 外部からではなく内部から: ラボのサービスは外部に公開されておらず、passes-api は
# 名前ではクラスター内からしか見えない。need_kubeconfig と need_tenant は、アクセスや
# テナント番号が設定されていない場合にスクリプトを早めに止める — さもないと全チェックが
# 一斉に失敗し、レポートから原因を判別できなくなる。
LAB_NAME="07-redis"
LAB_TITLE="ラボ7 · 遅いバックエンドの前に置くキャッシュ"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# チェック全体が参照する名前とアドレスは一箇所にまとめてある: スクリプトの本文を
# 探し回る必要はない。テナントアクセスがデフォルトの場所にない場合、COZY_KUBECONFIG は
# 外部から上書きできる。
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# スクリプト全体で使う2つの短縮関数: kget は lab クラスター(KUBECONFIG のもの)に、
# cozy は Cozystack 管理クラスターに話しかける。エラーメッセージは意図的に抑制している:
# ここでオブジェクトがないのは通常の状況であり、それについてはスクリプトが自分の言葉で
# ヒント付きに伝える。kubectl の他人任せのテキストではなく。
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# JSON からフィールドを取り出す。jq なしで: 素の macOS には jq はないが、python3 は
# 残りのチェックライブラリが動く場所ならどこにでもある。
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- 管理クラスター上の managed な Redis サービス ----------------------------
# Redis はあなたの lab クラスターではなく、管理クラスター上のテナントに住んでいる: これは
# managed サービスで、プラットフォームが自分で動かし続ける。テナント内の権限は人によって
# 異なるので、アクセス拒否も kubeconfig の欠如もラボを失敗にはしない — キャッシュの
# 働きは以下で直接、生のリクエストで確認する。それこそが本当の証拠だ。
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "テナント kubeconfig ${COZY_KUBECONFIG} が見つからない — Redis の状態は未確認" \
       "パスを指定してください: export COZY_KUBECONFIG=~/.kube/config"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "テナント ${TENANT_NS} 内の Redis アプリケーションを表示できなかった" \
         "テナントのロールがこのコマンドを許可していない可能性がある — これはラボのエラーではない。キャッシュの働きは以下で直接確認する"
  elif [ -z "$REDIS_LIST" ]; then
    fail "テナント ${TENANT_NS} には Redis アプリケーションが一つもない" \
         "ダッシュボードで作成してください: アプリケーションを作成 -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "managed Redis «${R_NAME}» は準備完了、データのコピー数: ${R_REPLICAS:-デフォルト}"
    else
      warn "Redis «${R_NAME}» は存在するが、準備完了を報告していない" \
           "ダッシュボードでその状態を確認してください。立ち上がりに3〜5分かかる"
    fi
    evidence "テナント内の Redis" "$REDIS_LIST"
  fi
fi

# --- 遅い名簿が所定の場所にあり、実際に遅いこと -----------------
# このチェックがないと「前後」の比較は無意味になる: 名簿が瞬時に応答するなら、
# 速くするものがなく、キャッシュで測るものもない。
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "名簿 ${HR} が動いていない" \
       "hr-legacy.yaml を適用し、kubectl describe pod -l app=hr-legacy を確認してください"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "名簿は ${HR_MS} ミリ秒で応答する — 速くする余地がある"
    evidence "名簿のレイテンシ" "/employee リクエストあたり ${HR_MS} ミリ秒"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "名簿 ${HR} がリクエストに応答しなかった" \
         "kubectl logs -l app=hr-legacy を確認してください"
  else
    warn "名簿は ${HR_MS} ミリ秒で応答する、測定には速すぎる" \
         "hr-legacy.yaml に MODE=hr と HR_DELAY=800ms が設定されているか確認してください"
  fi
fi

# --- アプリケーションがキャッシュ用に設定されていること ---------------------------------------------
# コンテナの環境変数を jsonpath ではなく python で解析する: ネストしたリストに対する
# jsonpath フィルタは kubectl のバージョンによって挙動が異なり、我々にとってはチェックが
# 全員で同じように動くことが重要だからだ。
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

# 苦情は順番に処理される — 最も一般的なものから最も具体的なものへ: アプリケーションがない、
# 変数がない、アドレスの代わりにプレースホルダが残っている。ここでの順序は装飾ではない:
# さもないと参加者は、サービス自体がまだデプロイされていない時点で「Redis のアドレスを
# 入れてください」という助言を受け取り、間違った場所でエラーを探すことになる。
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "lab クラスターにアプリケーション ${APP} がない" \
       "passes-api.yaml を適用し、あなたの Harbor のアドレスを入れてください"
elif [ -z "$REDIS_ADDR" ]; then
  fail "${APP} に REDIS_ADDR 変数が設定されていない — キャッシュが無効" \
       "パッチを適用してください: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "パッチにプレースホルダのアドレス REDIS-ADDR が残っている" \
       "あなたの Redis のアドレスを入れてください、例えば rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "アプリケーションはアドレス ${REDIS_ADDR} のキャッシュ用に設定済み、エントリの生存時間 ${TTL:-デフォルト} 秒"
fi

# 変数名が存在するかどうかだけを見て、その値はどこでも読まないし出力もしない。
# ラボのレポートは人々が互いに転送し、チケットに添付する — そこに入り込んだ
# パスワードは永久にそこに残る。
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "Redis のパスワードがアプリケーションに届いている(値: <非表示>)"
else
  fail "${APP} に REDIS_PASSWORD 変数が設定されていない" \
       "Redis は認証を要求する。redis-password シークレットを作成し、cache-patch.yaml を適用してください"
fi

# シークレットの欠如は失敗ではなく警告だ: パスワードは別の方法でも Pod に届けられる。
# ここでチェックしている性質は別のもの — マニフェストには値ではなく参照が入っている、
# ということだ。
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "Redis のパスワードを持つ redis-password シークレットが存在する"
else
  warn "クラスターに redis-password シークレットがない" \
       "作成してください: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- 主なチェック: キャッシュが実際に速度を上げること ----------------------------
# 1回目のリクエストが確実にミスになるよう、識別子は意図的に新しいものを取る。
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "サービス ${APP} が期待した JSON を返さなかった" \
       "kubectl logs -l app=passes-api を確認してください。イメージがこのラボの app/ から(タグ v2 で)ビルドされているか確認してください"
  evidence "サービスが何を応答したか" "1回目のリクエスト: ${R1:-空}
2回目のリクエスト: ${R2:-空}"
elif [ "$MODE" != "redis" ]; then
  fail "アプリケーションがキャッシュは無効だと報告している(cache: ${MODE})" \
       "REDIS_ADDR 変数が稼働中の Pod に届いていない — kubectl rollout status deployment/${APP} を確認してください"
elif [ "$C1" = "True" ]; then
  warn "1回目のリクエストがすでにキャッシュから来た — 比較する相手がない" \
       "ありえない識別子の衝突。チェックをもう一度実行してください"
elif [ "$C2" != "True" ]; then
  fail "同じ識別子での2回目のリクエストが再びキャッシュにヒットしなかった" \
       "アプリケーションが Redis に書き込めていない: kubectl logs -l app=passes-api を確認してください。たいてい NOAUTH かタイムアウトが出ている"
  evidence "サービスの応答" "1回目:  ${R1}
2回目: ${R2}"
else
  ok "キャッシュが動作している: ミス ${T1} ミリ秒、ヒット ${T2} ミリ秒"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "1000より大きい")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "稼働中のサービスでの測定" "識別子: ${PROBE_ID}
1回目のリクエスト(ミス):   ${T1} ミリ秒
2回目のリクエスト(ヒット): ${T2} ミリ秒
効果: およそ ${SPEEDUP} 倍
エントリの生存時間: ${TTL:-デフォルト} 秒"

  # 厳密な部分: ヒットはミスより一桁速くなければならない。さもないと
  # 「キャッシュが動作している」は、キーが書き込まれたというだけで、利益がないことになる。
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "効果が測定できる: ヒットはミスよりおよそ ${SPEEDUP} 倍速い"
  else
    warn "キャッシュヒットが目立った効果を出していない(${T1} ミリ秒 対 ${T2} ミリ秒)" \
         "名簿が本当に遅いこと、そして Redis が同じ Pod 上にないことを確認してください"
  fi
fi

# --- サービスの何個のコピーが一つのキャッシュを共有するか --------------------------------------------
# キャッシュは全コピーで共有される — これはレポートで見る価値がある: ヒットはミスとは
# 別の Pod から来た可能性があり、それは正しい。
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "稼働中のサービスのコピー: ${API_PODS} 個(キャッシュは共有)"
  evidence "サービスのコピー" "$(kget pods -l app=passes-api -o wide)"
else
  fail "${APP} の稼働中のコピーが一つもない" \
       "kubectl describe pod -l app=passes-api を確認してください"
fi

finish
