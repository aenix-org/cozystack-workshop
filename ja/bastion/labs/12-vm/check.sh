#!/usr/bin/env bash
# ラボ12のチェック: 移行した仮想マシンが、コンテナ化アプリケーションとまったく同じように、
# プラットフォームの ingress とドメインを通じて外部に公開されていることを確認する。
#
# 「オブジェクトが作成された」ではなく、本質的に動作しているかを検証する:
#   1) テナントのドメイン名が HTTP 200 を返し、それが名簿ページであること、
#   2) 仮想マシン自体が起動している(Ready)こと、
#   3) マシンを公開する Ingress が存在すること。
# 1つ目が最も重要: これこそが名簿が外部から見えている証拠である。
#
# VM 上で、このラボのフォルダから実行する。テナントアクセスとテナント番号が必要:
#     export KUBECONFIG=~/.kube/config
#     export COZY_TENANT=workshopXX
#     cd labs/12-vm && ./check.sh
# ドメインのチェックはテナントアクセスがなくても動作する — curl だけで十分。テナント
# アクセスがなくてもスクリプトは失敗しない: テナント側のチェックをスキップし、その旨を伝える。
#
# スクリプトは何も変更しない — 読み取りと HTTP リクエストの送信のみ。後片付けの前に実行すること:
# マシンを削除した後はチェックするものが何も残らない。

# この2つの変数は lib.sh が拾う — レポートのヘッダーと、スクリプトが自身の隣に書き出す
# report-<ラボ>-<日付>.md ファイルの名前に入る。
LAB_NAME="12-vm"
LAB_TITLE="ラボ12 · コンテナの隣の仮想マシン"
# 共通チェックライブラリ: ok / fail / warn / evidence / finish はここから来る。
# パスはスクリプト自身の場所を基準に解決されるため、どのディレクトリから実行しても
# 同じように動作する。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# テナント番号は必須: namespace 名も、名簿が公開されるドメイン名も、これから組み立てられる。
# これがなければチェックするものがない。
need_tenant

# チェックする名前。VM はマシンの「注文」の名前、すなわち VMInstance オブジェクトの名前;
# `kubectl get vminstance` はこれで問い合わせる。実際に起動するインスタンスは別の名前:
# プラットフォームは注文を `vm-instance` チャートでデプロイし、チャート名がリリース名と
# 結合されて vm-instance-spravochnik になる。
VM=spravochnik
NS="tenant-${COZY_TENANT}"
# 進行役が事前に Ingress 経由で名簿を公開したドメイン。ブラウザで開くのと同じアドレス。
HOST="spravochnik.${COZY_TENANT}.workshop.aenix.io"
URL="http://${HOST}"

# テナントアクセスは必須ではない: ドメインは通常の curl でチェックする。KUBECONFIG が設定され、
# テナントが応答すれば — マシンの状態と Ingress のチェックを追加する。
TENANT_OK=0
if [ -n "${KUBECONFIG:-}" ] && kubectl -n "$NS" get vminstance >/dev/null 2>&1; then
  TENANT_OK=1
fi

# --- 最重要: 名簿がドメイン経由で外部から見える ---------------------------
# レスポンスコードとボディを別々に取得する: コードは「まだ ingress の後ろに誰もいない」(503)を
# 「間違った先を指している」(404)や「ドメインがまったくない」(000)と区別し、ボディは
# 応答しているのがランダムなスタブではなく名簿本体であることを裏付ける。
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)"
BODY="$(curl -s --max-time 10 "$URL" 2>/dev/null)"

case "$CODE" in
  200)
    case "$BODY" in
      *"Справочник сотрудников"*)
        ok "名簿が公開されました: ${URL} が 200 を返し、名簿ページを配信しています"
        evidence "ドメインの応答" "リクエスト: ${URL}
レスポンスコード: ${CODE}
$(printf '%s' "$BODY" | head -3)"
        ;;
      *)
        fail "${URL} は 200 を返しますが、これは名簿ページではありません" \
             "ドメインの後ろで別のものが応答しています; マシン内部のポート8080で待ち受けているのが名簿であることを確認してください"
        ;;
    esac
    ;;
  503)
    fail "ドメイン ${URL} が 503 を返しています — Ingress の後ろにまだ応答する者がいません" \
         "マシンがまだ起動中か、ポート8080の名簿サービスが立ち上がっていません; vminstance が Ready になるのを待ち、マシンのコンソールを確認してください"
    ;;
  000)
    fail "ドメイン ${URL} がまったく応答しません" \
         "ネットワークを確認してください; このホストの Ingress は進行役が作成します — ドメインがまったくない場合は進行役に尋ねてください"
    ;;
  *)
    fail "ドメイン ${URL} は 200 ではなく ${CODE} を返しています" \
         "404 は Ingress が間違ったサービスを指していることを意味します; 5xx はバックエンドが応答準備できていないことを意味します"
    ;;
esac

# --- テナント側: マシン本体とその公開 --------------------------
if [ "$TENANT_OK" -eq 0 ]; then
  warn "テナント側のチェックをスキップしました: KUBECONFIG 経由でテナントに到達できません" \
       "テナントアクセスを指定してください: export KUBECONFIG=~/.kube/config"
else
  # 「オブジェクトが存在するか」ではなく Ready 条件を尋ねる: マシンの注文は一瞬で作成されるが、
  # ゲストは3〜5分で立ち上がり、その間ずっとマシンは存在するのに名簿はまだ応答しない。
  if ! kubectl -n "$NS" get vminstance "$VM" >/dev/null 2>&1; then
    fail "テナント ${NS} に仮想マシン ${VM} がありません" \
         "ダッシュボードで VM Disk と VM Instance を作成するか、staff-directory-vm.yaml を適用してください"
  else
    VM_READY="$(kubectl -n "$NS" get vminstance "$VM" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [ "$VM_READY" = "True" ]; then
      ok "仮想マシン ${VM} が起動しています"
    elif [ -n "$VM_READY" ]; then
      fail "仮想マシン ${VM} は存在しますが、準備できていません (Ready=${VM_READY})" \
           "ダッシュボードでマシンのカードを確認してください; 初回の電源投入には3〜5分かかります"
    else
      warn "仮想マシン ${VM} は存在しますが、状態を読み取れませんでした" \
           "ダッシュボードで目視確認してください: 電源が入っているはずです"
    fi
    evidence "テナントの仮想マシン" "$(kubectl -n "$NS" get vminstance 2>/dev/null)"
  fi

  # Ingress は参加者ではなく進行役が作成する。ドメインが既に 200 を返していれば — 存在している;
  # 503/404 のときに公開が存在するかどうかがすぐ分かるよう、別途チェックする。
  if kubectl -n "$NS" get ingress spravochnik >/dev/null 2>&1; then
    ok "Ingress spravochnik が存在します — 名簿がテナント内に公開されています"
    evidence "テナントの Ingress" "$(kubectl -n "$NS" get ingress spravochnik 2>/dev/null)"
  else
    warn "テナント ${NS} に Ingress spravochnik が見つかりません" \
         "これは進行役が作成します; ドメインが既に 200 を返していれば心配ありません、そうでなければ進行役に連絡してください"
  fi
fi

finish
