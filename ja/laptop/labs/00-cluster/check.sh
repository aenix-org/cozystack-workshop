#!/usr/bin/env bash
# ラボ0のチェック: 学習用クラスターが起動し、そこに接続できていること。
#
# 「オブジェクトが作成された」ことではなく、クラスターが実質的に動作していることを検証します:
#   1) lab クラスターがアクセスファイル経由で応答する (KUBECONFIG=~/lab.kubeconfig)、
#   2) 少なくとも1つのノードが Ready 状態にある、
#   3) ノードに今後のアプリケーション用の空きリソースがある。
# COZY_TENANT が設定されている場合は、追加で管理クラスター側を確認し、Kubernetes/lab の
# 注文が Ready に達したこと、メトリクス収集が有効であること（無効だとラボ14が空になる）を見ます。
#
# 仮想マシン上で、このラボのフォルダから実行します:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # テナント側からのチェック用（任意）
#     cd labs/00-cluster && ./check.sh
#
# このスクリプトは読み取りのみ — クラスターの状態は変更しません。
LAB_NAME="00-cluster"
LAB_TITLE="ラボ0 · 自分専用の Kubernetes クラスター"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# lab クラスター自体へのアクセスがなければチェックするものは何もありません — これこそが
# ラボの主要な証拠です。KUBECONFIG が設定されていない、またはクラスターが応答しない場合、
# need_kubeconfig が分かりやすいヒントとともにスクリプトを停止します。
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) lab クラスターへの接続 -------------------------------------------
# need_kubeconfig は既にサーバーが応答することを確認済みです。これを個別の結果として
# 記録し、サーバーのバージョンをレポートに入れます。
KVER="$(server_version)"
ok "lab クラスターが応答しています — アクセスファイルは有効です"
[ -n "$KVER" ] && evidence "lab クラスターのサーバーバージョン" "$KVER"

# --- 2) 稼働中のノード ---------------------------------------------------------
# Ready 状態のノードがいくつあるか数えます。リストが空の場合は、クラスターは起動したが
# ノードグループ md0 がまだ展開中であることを意味します。
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "稼働中のノード: ${TOTAL_NODES} 中 ${READY_NODES} が Ready 状態"
  [ -n "$NODES_WIDE" ] && evidence "クラスターのノード" "$NODES_WIDE"
else
  fail "Ready 状態のノードが1つもありません（ノード総数: ${TOTAL_NODES:-0}）" \
       "ノードグループ md0 が展開されるまで数分待ってください。状態は lab アプリケーションのダッシュボード、または: kubectl get nodes で確認できます"
  evidence "クラスターのノード" "${NODES_WIDE:-ノードなし}"
fi

# --- 3) 今後のアプリケーション用の空きがあるか --------------------------------
# 最初のノードの allocatable: リソースがなければ、これ以降は何も起動しません。
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "ノードにアプリケーション用のリソースがあります（ノード上: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM）"
  evidence "ノードの空きリソース (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "ノードの空きリソースを読み取れませんでした" \
       "通常は一時的なものです — 1分後に再試行してください"
fi

# --- 4) 管理クラスター側から（テナントが設定されている場合） -----------------
# ラボ0には必須ではありません: 上のクラスター自体への接続で既にすべて証明されています。
# ただしテナントアクセスがある場合は、注文を確認しメトリクス収集をチェックします。
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "テナントアクセス ${COZY_KUBECONFIG} が見つかりません — 管理側でのクラスター注文は確認されませんでした" \
         "これはラボの失敗ではありません。パスは次で設定できます: export COZY_KUBECONFIG=~/.kube/workshop"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "管理クラスター上で Kubernetes/lab の注文が Ready 状態です"
    elif [ -n "$LAB_READY" ]; then
      warn "Kubernetes/lab の注文はまだ Ready ではありません（現在: ${LAB_READY}）" \
           "クラスターは既に応答しており、プラットフォームがまだ目標状態へと調整中です。次を確認してください: kubectl --kubeconfig ~/.kube/workshop -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "テナント ${TENANT_NS} に Kubernetes/lab の注文が見つかりませんでした" \
           "クラスターに別の名前を付けた場合は自分の名前に置き換えてください。または、テナント内のロールがこのコマンドを許可していません（ラボのエラーではありません）"
    fi
    # メトリクス収集: ラボ14は、有効化した時点から蓄積されるデータに依存します。
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "メトリクス収集が有効です（ラボ14で必要になります）"
    elif [ -n "$LAB_READY" ]; then
      warn "メトリクス収集が無効です — ラボ14はデータなしのままになります" \
           "有効化するには: ダッシュボード → lab アプリケーション → Addons → Monitoring agents（メトリクスは遡って現れません）"
    fi
  fi
else
  warn "COZY_TENANT が設定されていません — 管理クラスター側からのチェックはスキップされます" \
       "ラボ0には必須ではありません。有効化するには: export COZY_TENANT=workshopXX"
fi

finish
