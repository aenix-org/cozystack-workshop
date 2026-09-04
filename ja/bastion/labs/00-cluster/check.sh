#!/usr/bin/env bash
# ラボ0のチェック: 学習用クラスタが起動し、あなたが接続できていること。
#
# 「オブジェクトが作成された」ではなく、クラスタが実質的に動作していることを確認します:
#   1) lab クラスタがあなたのアクセスファイル (KUBECONFIG=~/lab.kubeconfig) 経由で応答する、
#   2) 少なくとも 1 つのノードが Ready 状態である、
#   3) ノードに今後のアプリケーション用の空きリソースがある。
# COZY_TENANT が設定されている場合 — さらに管理クラスタ側で、Kubernetes/lab の注文が
# Ready に達し、メトリクス収集が有効になっていること (これが無いとラボ14 が空になります) を確認します。
#
# 仮想マシン上で、このラボのフォルダから実行します:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # テナント側のチェック用 (任意)
#     cd labs/00-cluster && ./check.sh
#
# このスクリプトは読み取りのみ — クラスタの状態は変更しません。
LAB_NAME="00-cluster"
LAB_TITLE="ラボ0 · 自分の Kubernetes クラスタ"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# lab クラスタ自体へのアクセスが無ければ確認するものはありません — これこそがラボの主要な
# 証拠です。KUBECONFIG が設定されていない、またはクラスタが応答しない場合、need_kubeconfig が
# 分かりやすいヒントとともにスクリプトを停止します。
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) lab クラスタへの接続 -------------------------------------------------
# need_kubeconfig はすでにサーバが応答することを確認済みです。これを個別の結果として
# 記録し、サーバのバージョンをレポートに記載します。
KVER="$(server_version)"
ok "lab クラスタが応答しています — アクセスファイルは有効です"
[ -n "$KVER" ] && evidence "lab クラスタのサーババージョン" "$KVER"

# --- 2) ノードが稼働中 -------------------------------------------------------
# Ready 状態のノードがいくつあるかを数えます。リストが空の場合は、クラスタは起動したが
# ノードグループ md0 がまだ展開中であることを意味します。
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "ノードが稼働中: ${TOTAL_NODES} 個中 ${READY_NODES} 個が Ready 状態です"
  [ -n "$NODES_WIDE" ] && evidence "クラスタのノード" "$NODES_WIDE"
else
  fail "Ready 状態のノードが 1 つもありません (ノード総数: ${TOTAL_NODES:-0})" \
       "ノードグループ md0 が展開されるまで数分お待ちください; 状態は lab アプリケーションのダッシュボード、または: kubectl get nodes で確認できます"
  evidence "クラスタのノード" "${NODES_WIDE:-ノードがありません}"
fi

# --- 3) 今後のアプリケーション用の空きがあるか ------------------------------
# 最初のノードの allocatable: リソースが無ければ、これ以降は何も起動しません。
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "ノードにアプリケーション用のリソースがあります (ノード上: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "ノードの空きリソース (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "ノードの空きリソースを読み取れませんでした" \
       "通常は一時的なものです — 1 分後に再試行してください"
fi

# --- 4) 管理クラスタ側から (テナントが設定されている場合) --------------------
# ラボ0 には必須ではありません: 上のクラスタ自体への接続がすでにすべてを証明しています。
# ただしテナントアクセスがある場合 — 注文を確認し、メトリクス収集をチェックします。
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "テナントアクセス ${COZY_KUBECONFIG} が見つかりません — 管理クラスタ上のクラスタ注文は確認されませんでした" \
         "これはラボの失敗ではありません; パスは次で設定します: export COZY_KUBECONFIG=~/.kube/config"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "管理クラスタ上で Kubernetes/lab の注文が Ready 状態です"
    elif [ -n "$LAB_READY" ]; then
      warn "Kubernetes/lab の注文がまだ Ready ではありません (現在: ${LAB_READY})" \
           "クラスタはすでに応答していますが、プラットフォームがまだ目標状態へ調整中です; 次を確認してください: kubectl --kubeconfig ~/.kube/config -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "テナント ${TENANT_NS} に Kubernetes/lab の注文が見つかりませんでした" \
           "クラスタに別の名前を付けた場合は — 自分の名前に置き換えてください; またはテナント内のロールがこのコマンドを許可していません (ラボのエラーではありません)"
    fi
    # メトリクス収集: ラボ14 は有効化した時点から蓄積されるデータに依存します。
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "メトリクス収集が有効です (ラボ14 で必要になります)"
    elif [ -n "$LAB_READY" ]; then
      warn "メトリクス収集が無効です — ラボ14 はデータ無しになります" \
           "有効化: ダッシュボード → lab アプリケーション → Addons → Monitoring agents (メトリクスは遡って現れません)"
    fi
  fi
else
  warn "COZY_TENANT が設定されていません — 管理クラスタ側のチェックはスキップされました" \
       "ラボ0 には必須ではありません; 有効化するには: export COZY_TENANT=workshopXX"
fi

finish
