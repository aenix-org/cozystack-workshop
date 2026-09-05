#!/usr/bin/env bash
# ラボ12のチェック: 移行した仮想マシンが、プラットフォームの ingress とドメインを通じて
# 外部に公開されている — コンテナ化されたアプリケーションとまったく同じように。
#
# 「オブジェクトが作成された」ことではなく、実際に機能していることを確認する:
#   1) テナントのドメイン名が HTTP 200 を返し、それが名簿ページであること、
#   2) 仮想マシン自体が起動している (Ready) こと、
#   3) マシンを公開している Ingress が存在すること。
# 1番目が最も重要: それこそが名簿が外部から見えている証拠である。
#
# ノートPC上で、このラボのフォルダから実行する。テナントアクセスとテナント番号が必要:
#     export KUBECONFIG=~/.kube/workshop
#     export COZY_TENANT=workshopXX
#     cd labs/12-vm && ./check.sh
# ドメインのチェックはテナントアクセスがなくても動く — curl だけで十分。テナントアクセスが
# なくてもスクリプトは失敗しない: テナント側のチェックをスキップし、その旨を伝える。
#
# このスクリプトは何も変更しない — 読み取りと HTTP リクエストの送信だけ。片付けの前に実行すること:
# マシンを削除した後ではチェックするものが何もなくなる。

# この2つの変数は lib.sh が拾う — レポートのヘッダーと、スクリプトが自身の隣に置く
# ファイル名 report-<ラボ>-<日付>.md に入る。
LAB_NAME="12-vm"
LAB_TITLE="ラボ12 · コンテナの隣の仮想マシン"
# 共通チェックライブラリ: ok / fail / warn / evidence / finish はここから来る。
# パスはスクリプト自身の場所を基準に解決されるので、どのディレクトリから実行しても
# 同じように動く。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# テナント番号は必須: そこから namespace 名と、名簿が公開されているドメイン名の両方が
# 組み立てられる。それがないとチェックするものがない。
need_tenant

# チェックする名前。VM はマシンの「注文」の名前、つまり VMInstance オブジェクトの名前;
# `kubectl get vminstance` はこれについて問い合わせる。実際に起動しているインスタンスは
# 別の名前になる: プラットフォームは注文を `vm-instance` チャートでデプロイし、チャート名が
# リリース名と連結されて、vm-instance-spravochnik になる。
VM=spravochnik
NS="tenant-${COZY_TENANT}"
# ホストが Ingress を通じて事前に名簿を公開したドメイン。ブラウザで開くのと同じアドレス。
HOST="spravochnik.${COZY_TENANT}.workshop.aenix.io"
URL="http://${HOST}"

# テナントアクセスは必須ではない: ドメインは通常の curl でチェックされる。KUBECONFIG が
# 設定されていてテナントが応答すれば — マシンの状態と Ingress のチェックを追加する。
TENANT_OK=0
if [ -n "${KUBECONFIG:-}" ] && kubectl -n "$NS" get vminstance >/dev/null 2>&1; then
  TENANT_OK=1
fi

# --- 最重要: 名簿がドメイン経由で外部から見える -------------------------
# 応答コードとボディを別々に取得する: コードは「ingress の後ろにまだ誰もいない」(503) と
# 「間違った場所に導いている」(404) と「ドメインがまったくない」(000) を区別し、
# ボディはランダムなスタブではなく、まさに名簿が応答していることを裏付ける。
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)"
BODY="$(curl -s --max-time 10 "$URL" 2>/dev/null)"

case "$CODE" in
  200)
    case "$BODY" in
      *"社員名簿"*)
        ok "名簿が公開されている: ${URL} は 200 を返し、名簿ページを配信している"
        evidence "ドメイン経由の応答" "リクエスト: ${URL}
応答コード: ${CODE}
$(printf '%s' "$BODY" | head -3)"
        ;;
      *)
        fail "${URL} は 200 を返すが、名簿ページではない" \
             "ドメインの後ろで別のものが応答している; マシン内部のポート 8080 でリッスンしているのがまさに名簿であることを確認してください"
        ;;
    esac
    ;;
  503)
    fail "ドメイン ${URL} は 503 を返す — Ingress の後ろにまだ応答できる者がいない" \
         "マシンがまだ起動中か、ポート 8080 の名簿サービスが立ち上がっていない; vminstance が Ready になるのを待ち、マシンのコンソールを確認してください"
    ;;
  000)
    fail "ドメイン ${URL} がまったく応答しない" \
         "ネットワークを確認してください; このホストの Ingress はホスト役が作成する — ドメインがまったくなければ、その人に尋ねてください"
    ;;
  *)
    fail "ドメイン ${URL} は 200 ではなく ${CODE} を返す" \
         "404 は Ingress が間違ったサービスに導いていることを意味する; 5xx はバックエンドが応答する準備ができていないことを意味する"
    ;;
esac

# --- テナント側: マシン自体とその公開 --------------------------
if [ "$TENANT_OK" -eq 0 ]; then
  warn "テナント側のチェックをスキップ: テナントに KUBECONFIG 経由で到達できない" \
       "テナントアクセスを指定してください: export KUBECONFIG=~/.kube/workshop"
else
  # 「オブジェクトが存在するか」ではなく Ready 条件を問い合わせる: マシンの注文は1秒で
  # 作成されるが、ゲストは3〜5分かけて立ち上がり、その間ずっとマシンは存在するのに
  # 名簿はまだ応答しない。
  if ! kubectl -n "$NS" get vminstance "$VM" >/dev/null 2>&1; then
    fail "テナント ${NS} に仮想マシン ${VM} がない" \
         "ダッシュボードで VM Disk と VM Instance を作成するか、staff-directory-vm.yaml を適用してください"
  else
    VM_READY="$(kubectl -n "$NS" get vminstance "$VM" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [ "$VM_READY" = "True" ]; then
      ok "仮想マシン ${VM} は起動している"
    elif [ -n "$VM_READY" ]; then
      fail "仮想マシン ${VM} は存在するが、準備ができていない (Ready=${VM_READY})" \
           "ダッシュボードでマシンのカードを確認してください; 初回起動は3〜5分かかります"
    else
      warn "仮想マシン ${VM} は存在するが、状態を読み取れなかった" \
           "ダッシュボードで自分の目で確認してください: 電源が入っているはずです"
    fi
    evidence "テナントの仮想マシン" "$(kubectl -n "$NS" get vminstance 2>/dev/null)"
  fi

  # Ingress は参加者ではなくホスト役が作成する。ドメインがすでに 200 を返していれば — それは
  # 存在している; 503/404 の際に公開が存在するかどうかがすぐ分かるよう、別々にチェックする。
  if kubectl -n "$NS" get ingress spravochnik >/dev/null 2>&1; then
    ok "Ingress spravochnik が存在する — 名簿がテナント内で公開されている"
    evidence "テナントの Ingress" "$(kubectl -n "$NS" get ingress spravochnik 2>/dev/null)"
  else
    warn "テナント ${NS} に Ingress spravochnik が見つからない" \
         "これはホスト役が作成する; ドメインがすでに 200 を返していれば心配ない、そうでなければホスト役に連絡してください"
  fi
fi

finish
