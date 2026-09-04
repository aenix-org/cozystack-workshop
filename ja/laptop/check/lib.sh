#!/usr/bin/env bash
# ラボ検証スクリプト用の共通ライブラリ。
# 次のように読み込む:  . "$(dirname "$0")/../../check/lib.sh"
#
# `set -e` は意図的に使っていない。スクリプトはすべてのチェックを実行して全体像を
# 示さなければならず、最初の失敗で止まってはならない。読者はまさに詰まったときに
# これを実行する。途中で打ち切るのは答えの半分を隠すことになる。

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# 色は出力が端末に向かうときだけ。ファイルや CI ではエスケープシーケンスが
# ゴミとして読まれてしまう。
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

# --- 機械可読な結果 ----------------------------------------------------------
# result-<ラボ>.json は人間向けレポートと並行して作られ、チェックの識別子と
# その結果だけを含む。文言、コマンド出力、証跡はそこには入らない。markdown
# レポートにはコンテナのログの末尾、外部ロードバランサのアドレス、ノードの
# アドレス、アクセスファイルのパスとユーザー名がたまっていく。それを正規表現で
# 洗い出すのは当てにならない。確実なのは、そもそも生成しないことだ。
#
# 識別子はそれ自体から導出される。ラボ内でのチェックの通し番号に、文言の短い
# ハッシュを加えたもの。番号は安定性を与え、ハッシュはテキストのひそかな改変を
# 捕らえる。文言が変えられれば、サービスはそれを見て、同じチェックとして黙って
# 受け入れることはしない。
_checks=()
_seq=0
_record() {   # _record <ステータス> <文言>
  _seq=$((_seq + 1))
  local h
  h="$(printf '%s' "$2" | shasum -a 256 2>/dev/null | cut -c1-8)"
  [ -n "$h" ] || h="00000000"
  _checks+=("$(printf '%s-%02d-%s:%s' "$LAB_NAME" "$_seq" "$h" "$1")")
}

ok() {
  _pass=$((_pass + 1))
  _record ok "$1"
  printf '%s[  OK  ]%s %s\n' "$_C_OK" "$_C_OFF" "$1"
  _lines+=("- **OK** — $1")
}

# fail "何が問題か" "それにどう対処するか"
fail() {
  _record fail "$1"
  _fail=$((_fail + 1))
  printf '%s[ FAIL ]%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **FAIL** — $1")
  [ -n "${2:-}" ] && _lines+=("  - 対処方法: $2")
}

warn() {
  _record warn "$1"
  _warn=$((_warn + 1))
  printf '%s[ WARN ]%s %s\n' "$_C_WARN" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **WARN** — $1")
  [ -n "${2:-}" ] && _lines+=("  - 備考: $2")
}

# evidence "見出し" "値" — アーティファクトに入り、端末には出力されない。
# 証跡は、レポートを誰かに見せたときに意味を持つように存在する。
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

# 早期終了でもレポートは残さなければならない。README は「レポートを添えて
# コミュニティへ」と勧めているのに、以前はクラスタに到達できないと添えるものが
# 何もなかった。つまり、まさにレポートが必要なその場面でレポートが無かった。
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "環境変数 KUBECONFIG が設定されていません" \
         "まず: export KUBECONFIG=~/lab.kubeconfig (新しい端末ウィンドウごとに)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "KUBECONFIG=${KUBECONFIG} でクラスタが応答しません" \
         "kubectl get nodes が応答なしでハングする場合 — クラスタのコントロールプレーンが起動していません。ダッシュボードで Kubernetes アプリケーションの状態を、テナントのイベントでクォータ超過 (exceeded quota) を確認してください"
    evidence "アクセスファイル" "$KUBECONFIG"
    evidence "クラスタの応答" "$(kubectl get nodes 2>&1 | head -5)"
    finish; exit 1
  fi
}

need_tenant() {
  if [ -z "${COZY_TENANT:-}" ]; then
    printf '%s[ FAIL ]%s 環境変数 COZY_TENANT が設定されていません\n' "$_C_FAIL" "$_C_OFF"
    printf '         %sたとえば: export COZY_TENANT=workshop07%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

# GNU 拡張なしの時刻。macOS の BSD date は `-d` を理解しない。
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

# 機械可読な結果の保存先。意図的にリポジトリの外に置く。クローン内だと最初の
# `git pull` やブランチ切り替えで消えてしまうが、これらは数週間かけて集められる。
LAB_RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"

_write_result_json() {
  mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || return 0
  # クラスタ識別子 — kube-system 名前空間の uid。同一クラスタ上のすべての実行で
  # 同じであり、人ごとに異なる。そして肝心なのは、テナント名とは違って「手で
  # 入力する」ことができない点だ。
  local cluster_uid=""
  cluster_uid="$(kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  local kver=""
  kver="$(server_version 2>/dev/null || true)"
  CHECKS_LIST="$(printf '%s\n' "${_checks[@]:-}")" \
  LAB="$LAB_NAME" VERDICT="$1" P="$_pass" F="$_fail" W="$_warn" \
  CUID="$cluster_uid" KVER="$kver" TEN="${COZY_TENANT:-}" WHEN="$(_now)" \
  python3 - "$LAB_RESULTS_DIR/result-${LAB_NAME}.json" <<'PYEOF'
import json, os, sys
checks = []
for line in os.environ.get("CHECKS_LIST", "").split("\n"):
    line = line.strip()
    if not line or ":" not in line:
        continue
    cid, status = line.rsplit(":", 1)
    checks.append({"id": cid, "status": status})
doc = {
    "schema_version": 1,
    "lab": os.environ["LAB"],
    "verdict": os.environ["VERDICT"],
    "finished_at": os.environ["WHEN"],
    "totals": {"pass": int(os.environ["P"]), "fail": int(os.environ["F"]),
               "warn": int(os.environ["W"])},
    "env": {"kubernetes_server_version": os.environ.get("KVER") or None,
            "cluster_uid": os.environ.get("CUID") or None,
            "tenant": os.environ.get("TEN") or None},
    "checks": checks,
}
with open(sys.argv[1], "w") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=1)
PYEOF
}

finish() {
  local total=$((_pass + _fail + _warn))
  local report="report-${LAB_NAME}-$(_stamp).md"
  local verdict

  if [ "$_fail" -eq 0 ]; then
    verdict="ラボ合格"
  else
    verdict="未解決の項目があります"
  fi

  _write_result_json "$([ "$_fail" -eq 0 ] && echo passed || echo failed)"

  printf '\n'
  printf 'チェック: %d · 合格: %d · 失敗: %d · 警告: %d\n' \
    "$total" "$_pass" "$_fail" "$_warn"
  if [ "$_fail" -eq 0 ]; then
    printf '%s%s%s\n' "$_C_OK" "$verdict" "$_C_OFF"
  else
    printf '%s%s%s\n' "$_C_FAIL" "$verdict" "$_C_OFF"
  fi

  {
    echo "# レポート: ${LAB_TITLE}"
    echo
    echo "- 日付: $(_now)"
    echo "- 結果: **${verdict}**"
    echo "- チェック: ${total} (合格 ${_pass}, 失敗 ${_fail}, 警告 ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- テナント: \`${COZY_TENANT}\`"
    echo
    echo "## チェック"
    echo
    printf '%s\n' "${_lines[@]}"
    if [ "${#_evidence[@]}" -gt 0 ]; then
      echo
      echo "## 証跡"
      echo
      printf '%s\n' "${_evidence[@]}"
    fi
    echo
    echo "---"
    echo
    echo "このレポートは Cozystack ラボの \`check.sh\` スクリプトによって生成されました。"
    echo "マニフェストが適用されたという事実ではなく、実際の動作を本質的に検証しました。"
  } > "$report"

  printf 'レポート: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# ほかでもない「サーバー」のバージョン。`kubectl version -o json` はクライアントと
# サーバーの両方を出力し、gitVersion への素朴な grep は最初に一致したもの —
# クライアント側 — を取ってしまい、レポートがクラスタのバージョンについて嘘を
# つき始める。ここは間違えやすいので、ライブラリに切り出してある。
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# 人間が読めるサイズ。Kubernetes は allocatable を Ki で返したり生のバイト数で
# 返したりし、レポート中の「3258002390」は読者に何も伝えない。
human_bytes() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, re
v = sys.argv[1].strip()
m = re.fullmatch(r'(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|K|M|G|T)?', v)
if not m:
    print(v); raise SystemExit
n = float(m.group(1))
mult = {'Ki':1024,'Mi':1024**2,'Gi':1024**3,'Ti':1024**4,
        'K':1000,'M':1000**2,'G':1000**3,'T':1000**4}.get(m.group(2), 1)
b = n * mult
for unit, size in (('Gi',1024**3), ('Mi',1024**2), ('Ki',1024)):
    if b >= size:
        print(f"{b/size:.1f}{unit}"); break
else:
    print(f"{int(b)}B")
PY
}

# 使い捨ての Pod でコマンドを実行し、秘密情報はコマンドライン引数ではなく、
# 一時的な Secret から設定した環境変数を通じて渡す。
#
# なぜこうするか。Pod の args に入るものはすべて、`get pods` を持つ誰にでも見え、
# etcd に残り、監査ログに入り、ノード上の `ps` に現れる。データベースのラボは、
# コマンドラインのパスワードは悪い慣行だと個別に説明している。まさにそれをやる
# スクリプトでラボを検証するのは、二重基準になってしまう。
#
# 使い方:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c '$KEY1 を読むコマンド'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # Secret は stdin から作られるので、値は kubectl の引数に入らない。
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # securityContext もここでは必須。これがないと `restricted` プロファイルの
  # クラスタで Pod が作られず、データベースのラボのチェックが動かない。
  local cmd_json
  cmd_json="$(printf '%s\n' "$@" | python3 -c 'import sys,json;print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image="$image" --pod-running-timeout=90s \
    --overrides="{\"spec\":{\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65532,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"$name\",\"image\":\"$image\",\"stdin\":true,\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}},\"envFrom\":[{\"secretRef\":{\"name\":\"$sec\"}}],\"command\":$cmd_json}]}}" \
    2>/dev/null
  local rc=$?

  kubectl delete secret "$sec" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# `restricted` プロファイルを通過する securityContext 付きの override を組み立てる。
# 別に切り出してある: 同じ上乗せがどの使い捨て Pod にも必要で、これがないと
# チェックスクリプトが厳格なクラスタで動かない。
# コマンド引数は「一つずつ別々に」渡し、JSON は python が組み立てる。bash で
# クオートを手作業でエスケープするのは、すでに壊れた override と Pod の無言の
# 失敗を招いており、そのエラーは 2>/dev/null に飲み込まれていた。
_restricted_overrides() {
  local name="$1" image="$2"; shift 2
  python3 - "$name" "$image" "$@" <<'PYJSON'
import sys, json
name, image, *cmd = sys.argv[1:]
print(json.dumps({"spec": {
    "securityContext": {"runAsNonRoot": True, "runAsUser": 65532,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": name, "image": image, "stdin": True,
                    "securityContext": {"allowPrivilegeEscalation": False,
                                        "capabilities": {"drop": ["ALL"]}},
                    "command": cmd}]}}))
PYJSON
}

# 使い捨ての Pod でコマンドを実行し、その出力を返す。
# クラスタ内部からのサービス到達性を確認する場面で必要。ノートPCからは
# ClusterIP が見えない。Pod はどんな場合でも自分で後始末する。
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # securityContext は必須: `restricted` プロファイルのクラスタでは、これがない
  # Pod は作られず、参加者はラボをまったく検証できなくなる。
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm` は、クライアントがアタッチしている間だけ Pod を削除する。切断、
  # タイムアウト、Ctrl+C では Pod が残る。明示的な削除は、スクリプトがクラスタを
  # 散らかさないためのもの。
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# 「複数」のリクエストの応答を連続で集め、1 行に 1 件ずつ返す。
#
# サービスの背後に複数のレプリカがあるとき、1 回のリクエストはくじ引きだ。同じ
# ラベルを持つ無関係な Pod がロードバランシングに入り込むが、単発のサンプルでは
# それに当たらないことがあり、チェックはすり替えられたコンテンツで嬉々として
# 緑になる。実測: 20 回のうち 8 回が偽物へ行き、チェックは 4 回連続で「合格」と
# 言った。
in_cluster_curl_many() {
  local url="$1" times="${2:-8}"
  local name="check-$$-$RANDOM"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      sh -c "for i in \$(seq 1 $times); do curl -s --max-time 10 '$url'; echo; done")" \
    2>/dev/null
  local rc=$?
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}
