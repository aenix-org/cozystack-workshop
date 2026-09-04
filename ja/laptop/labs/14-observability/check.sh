#!/usr/bin/env bash
# ラボ14のチェック: 可観測性が実際に機能していること。
#
# 「参加者がグラフを見た」ことは検証できず、できるふりをするのは不誠実だ。
# そこで、グラフが成り立つために欠かせないものを確認する:
#   1) メトリクス収集エージェントがクラスタで動いていること、
#   2) 収集したものを、どこか虚空ではなく自分のテナントへ送っていること、
#   3) ログ収集も機能していること — これがなければラボの半分は無意味になる、
#   4) グラフ上で見つけられる、ラボ3の負荷の痕跡がクラスタに残っていること。

LAB_NAME="14-observability"
LAB_TITLE="ラボ14 · 可観測性: グラフの中から自分のスパイクを見つける"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- 収集用 namespace -------------------------------------------------------
# namespace の存在だけでは何も証明できない: プラットフォームは同じ場所に metrics-server も置き、
# それは etcd を持つ任意のクラスタにインストールされ、アドオンには依存しない。ここで存在を確認するのは、
# 「クラスタに到達できない」と「収集が無効」を区別するためだけだ。
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "クラスタに namespace ${MON_NS} がありません — クラスタの応答が想定と異なります" \
       "アドオンを有効化してください: ダッシュボード -> Kubernetes -> lab -> 編集 -> Addons -> Monitoring agents。注意: レコードはこの時点以降にのみ現れます"
  finish
  exit $?
fi

# --- メトリクスエージェント -------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "メトリクス収集エージェントが動いています (vmagent ポッド: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "メトリクス収集エージェントは存在しますが動いていません (${VMAGENT_TOTAL} 個中 ${VMAGENT_RUNNING} 個が Running)" \
       "原因を確認してください: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "${MON_NS} に vmagent ポッドが1つもありません — Monitoring agents アドオンが無効です" \
       "有効化してください: ダッシュボード -> Kubernetes -> lab -> 編集 -> Addons -> Monitoring agents。レコードが蓄積され始めるのはこの時点以降で、過去は取り戻せません"
fi
evidence "${MON_NS} の収集ポッド" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- メトリクスは正確にどこへ送られるか -------------------------------------
# 虚空へ書き込んでいる稼働中エージェントは、正常なものとまったく同じに見える。
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "メトリクスはテナントへ送られています${TARGET_NS:+ (${TARGET_NS})}"
      ;;
    *)
      warn "メトリクスはテナント固有には見えないアドレスへ送られています" \
           "ホストが共有ストレージを設定した場合はこれで正常なこともあります; アドレスは証跡にあります"
      ;;
  esac
  evidence "メトリクスの送信先" "$RW_URL"
else
  warn "メトリクスの送信先アドレスを読み取れませんでした" \
       "手動で確認してください: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- ログ収集 --------------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "ログ収集がすべてのノードで動いています (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "ログ収集がすべてのノードでは動いていません (${FB_DESIRED} 個中 ${FB_READY:-0} 個)" \
       "確認してください: kubectl -n ${MON_NS} get pods | grep fluent-bit — これがないとログ検索のステップは動きません"
else
  warn "ログコレクタ fluent-bit が見つかりませんでした" \
       "Grafana の vlogs-generic ソースは空になります; ログ検索のステップは実行できません"
fi

# --- グラフで探すものがあるか ----------------------------------------------
# メトリクスが完璧に収集されていても、負荷がなかったなら探すものは何もない。
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "負荷の痕跡があります: オートスケーリングが作動しました (最後は ${LAST_SCALE})"
    evidence "オートスケーリングの状態" "$(kubectl get hpa rickroll 2>/dev/null)
最後の作動: ${LAST_SCALE}
現在のレプリカ数: ${CUR:-?}, 要求数: ${DES:-?}"
  else
    warn "オートスケーリングは設定されていますが一度も作動していません" \
         "レプリカ増加のステップは見つかりません; fortio ジェネレータでラボ3の負荷を再現してください"
  fi
else
  warn "クラスタに rickroll という名前の HorizontalPodAutoscaler がありません" \
       "このラボのグラフ関連ステップはラボ3に依存します; それがないと CPU スパイクだけは見つかりますが、段差は見つかりません"
fi

# --- アプリケーション自体のメトリクス --------------------------------------
# 間接的だが本質的: アプリケーションのポッドが生きていれば、その消費量はグラフに現れる。
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "アプリケーションのポッドが揃っています (${APP_PODS} 個) — その消費量はグラフで見えます"
  evidence "アプリケーションのポッド" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "クラスタに rickroll アプリケーションのポッドがありません" \
       "ラボ3の時点の履歴メトリクスはそのまま保存されています; Grafana でその時間範囲を指定するだけです"
fi

# --- Grafana はどこにあるか -------------------------------------------------
# チェックではなく手助け: Grafana のアドレスは参加者が最も長く探すものだ。
: "${COZY_KUBECONFIG:=$HOME/.kube/workshop}"
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
           "${MON_TARGET} があなたの namespace でない場合、Grafana は共有です: アドレスはホストに尋ねてください"
      evidence "テナントのモニタリング" "モニタリング用 namespace: ${MON_TARGET}"
    fi
  else
    warn "テナント ${TNS} のメトリクスがどこへ行くのか特定できませんでした" \
         "Grafana のアドレスはホストに尋ねるか、ダッシュボードで見つけてください: Monitoring アプリケーション -> Ingress"
  fi
else
  warn "Grafana のアドレスが特定されていません" \
       "COZY_TENANT と COZY_KUBECONFIG を設定すれば、スクリプトが自動で見つけます; これはラボの合格には影響しません"
fi

finish
