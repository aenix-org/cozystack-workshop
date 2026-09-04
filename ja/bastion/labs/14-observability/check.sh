#!/usr/bin/env bash
# ラボ 14 のチェック: オブザーバビリティが実際に動作していること。
#
# 「参加者がグラフを見た」ことは検証できず、できるふりをするのは不誠実だ。
# そこで、グラフを成立させるために欠かせないものを検証する:
#   1) メトリクス収集エージェントがクラスタ内で稼働していること、
#   2) 収集したものを、どこでもない場所ではなく自分のテナントに送っていること、
#   3) ログ収集も動作していること — これなしではラボの半分が無意味になる、
#   4) ラボ 3 の負荷の痕跡がクラスタに残っており、グラフの中で見つけられること。

LAB_NAME="14-observability"
LAB_TITLE="ラボ 14 · オブザーバビリティ: グラフの中で自分のスパイクを見つける"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- 収集用 namespace -------------------------------------------------------
# namespace 自体は何も証明しない: プラットフォームは同じ場所に metrics-server も配置し、
# それは etcd を持つ任意のクラスタにインストールされ、アドオンには依存しない。この存在を
# 確認するのは「クラスタに到達できない」と「収集がオフ」を区別するためだけである。
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "クラスタに namespace ${MON_NS} がありません — クラスタが期待どおりに応答していません" \
       "アドオンを有効化してください: ダッシュボード -> Kubernetes -> lab -> 編集 -> Addons -> Monitoring agents。注意: レコードはこの瞬間からのみ現れます"
  finish
  exit $?
fi

# --- メトリクスエージェント -------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "メトリクス収集エージェントが稼働しています (vmagent ポッド数: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "メトリクス収集エージェントは存在しますが稼働していません (${VMAGENT_TOTAL} 個中 ${VMAGENT_RUNNING} 個が Running)" \
       "原因を確認してください: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "${MON_NS} に vmagent ポッドが 1 つもありません — Monitoring agents アドオンがオフです" \
       "有効化してください: ダッシュボード -> Kubernetes -> lab -> 編集 -> Addons -> Monitoring agents。レコードはこの瞬間から蓄積が始まり、過去は取り戻せません"
fi
evidence "${MON_NS} の収集ポッド" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- メトリクスが正確にどこへ送られるか -------------------------------------
# どこでもない場所へ書き込む稼働中のエージェントは、正常なものとまったく同じに見える。
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "メトリクスはテナントに送信されています${TARGET_NS:+ (${TARGET_NS})}"
      ;;
    *)
      warn "メトリクスがテナント用らしくないアドレスに送信されています" \
           "ホストが共有ストレージを設定した場合はこれで正常なこともあります。アドレスは証跡にあります"
      ;;
  esac
  evidence "メトリクスの送信先" "$RW_URL"
else
  warn "メトリクスの送信先アドレスを読み取れませんでした" \
       "手動で確認してください: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- ログ収集 ---------------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "ログ収集がすべてのノードで動作しています (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "ログ収集がすべてのノードで稼働しているわけではありません (${FB_DESIRED} 個中 ${FB_READY:-0} 個)" \
       "確認してください: kubectl -n ${MON_NS} get pods | grep fluent-bit — これなしではログ検索のステップが動作しません"
else
  warn "ログコレクター fluent-bit が見つかりませんでした" \
       "Grafana の vlogs-generic ソースは空になります。ログ検索のステップは実行できません"
fi

# --- グラフの中に探すものがあるか -------------------------------------------
# メトリクスが完璧に収集されていても、負荷がなければ探すものは何もない。
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "負荷の痕跡があります: オートスケーリングが作動しました (最終作動 ${LAST_SCALE})"
    evidence "オートスケーリングの状態" "$(kubectl get hpa rickroll 2>/dev/null)
最終作動: ${LAST_SCALE}
現在のレプリカ数: ${CUR:-?}, 必要数: ${DES:-?}"
  else
    warn "オートスケーリングは設定されていますが一度も作動していません" \
         "レプリカ増加のステップは見つかりません。fortio ジェネレーターでラボ 3 の負荷を再実行してください"
  fi
else
  warn "クラスタに rickroll という名前の HorizontalPodAutoscaler がありません" \
       "このラボのグラフのステップはラボ 3 に依存します。それなしでは CPU のスパイクしか見つからず、段差は見つかりません"
fi

# --- アプリケーション自体のメトリクス ---------------------------------------
# 間接的だが本質的: アプリケーションのポッドが生きていれば、その消費はグラフに現れる。
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "アプリケーションのポッドが揃っています (${APP_PODS} 個) — その消費はグラフに見えます"
  evidence "アプリケーションのポッド" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "クラスタに rickroll アプリケーションのポッドがありません" \
       "ラボ 3 の時間帯の履歴メトリクスは保存されています。Grafana でその時間範囲を設定するだけです"
fi

# --- Grafana はどこにあるか -------------------------------------------------
# チェックではなく手助け: Grafana のアドレスは参加者が最も長く探すものである。
: "${COZY_KUBECONFIG:=$HOME/.kube/config}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "あなたのメトリクス用の Grafana: https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
テナント ${TNS} のメトリクスは namespace ${MON_TARGET} に保存されています"
    else
      warn "あなたのテナントのモニタリングは ${MON_TARGET} にありますが、Grafana のアドレスを読み取れませんでした" \
           "もし ${MON_TARGET} があなたの namespace でなければ、Grafana は共有です。アドレスはホストに尋ねてください"
      evidence "テナントのモニタリング" "モニタリングのある namespace: ${MON_TARGET}"
    fi
  else
    warn "テナント ${TNS} のメトリクスがどこへ行くのか特定できませんでした" \
         "Grafana のアドレスはホストに尋ねるか、ダッシュボードで探してください: Monitoring アプリケーション -> Ingress"
  fi
else
  warn "Grafana のアドレスが特定されていません" \
       "COZY_TENANT と COZY_KUBECONFIG を設定すれば、スクリプトが自動で見つけます。ラボの合格には影響しません"
fi

finish
