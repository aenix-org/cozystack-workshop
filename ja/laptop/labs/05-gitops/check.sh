#!/usr/bin/env bash
# ラボ5のチェック: クラスタの状態は Git から届き、リコンサイルによって維持される。
#
# あなたの `lab` クラスタに対して、ラボのフォルダから、あなた自身が実行する:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# 何も変更しない — ただ確認し、レポートを出力するだけ: 何を確認したか、何が通ったか、
# 何が通らなかったか、および添付された根拠。
#
# 確認するのは「Flux がインストールされている」ではなく「仕組みが動いている」こと: ソースが読まれ、適用されたものが
# Flux に属し、サービスが応答し、リコンサイルが無効化されていない。インストール済みだが
# 一時停止された Flux は、ラボの意味を外したまま合格する最も一般的な方法だ。

LAB_NAME="05-gitops"
LAB_TITLE="ラボ5 · Git 上のインフラ"
# すべてのラボ共通の土台: ここから ok / fail / warn / evidence / finish と
# 環境チェックが提供される。パスはこのファイルの位置から解決されるため、スクリプトは
# 任意のフォルダから実行できる。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# クラスタへのアクセスファイルがなければ確認するものはない — 明確な理由とともに直ちに終了する。
need_kubeconfig

# ラボが作成する名前。一箇所にまとめてある: 参加者がオブジェクトを
# 別の名前で作った場合、スクリプト全体で名前を探すのではなく、ここで修正する。
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# オブジェクトや CRD がなくても失敗せずに、オブジェクトのフィールドを読む。
kget() { kubectl get "$@" 2>/dev/null; }

# --- Flux のサービス -----------------------------------------------------------
# 確認するのは「Pod が存在する」ではなく「Ready 状態のレプリカが少なくとも1つある」こと: Pod は
# ノードにメモリがなくて Pending のままぶら下がっていても、get pods の出力には現れうる。
# 両方のサービスが必須で、仕事を分担する: source-controller がリポジトリをダウンロードし、
# kustomize-controller がダウンロードしたものを適用する。後者がなければ何もクラスタに届かない。
if ! kget namespace flux-system >/dev/null; then
  fail "クラスタに flux-system 名前空間がありません" \
       "Flux がインストールされていません: flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "Flux のサービスが稼働しています: source-controller と kustomize-controller"
    evidence "Flux の Pod" "$(kget pods -n flux-system -o wide)"
  else
    fail "Flux のサービスが稼働していません:${FLUX_BAD}" \
         "kubectl get pods -n flux-system を確認してください。小さなノードではメモリが不足している可能性があります"
  fi
fi

# --- ソース: GitRepository ------------------------------------------------
# 3つの異なる結末があり、混同してはならない: オブジェクトがまったく存在しない; オブジェクトはあるが
# アドレスのプレースホルダが残っている; オブジェクトがあり本物のアドレスもあるが、Flux がリポジトリを
# 読めなかった。それぞれのケースで助言が異なるため、分岐も異なる。
#
# 成功のしるしは status.conditions から取る — これはオブジェクトの存在からの推測ではなく、
# Git へアクセスを試みた後に Flux 自身が報告するものだ。
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "クラスタに GitRepository 型がありません" \
       "Flux がインストールされていないか、source-controller なしでインストールされています"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "flux-system に ${GITREPO} という名前の GitRepository が見つかりません" \
         "自分のリポジトリのアドレスを差し込んで flux/gitrepository.yaml を適用してください"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "GitRepository にプレースホルダのアドレスが残っています" \
         "flux/gitrepository.yaml を開き、自分の GitHub リポジトリのアドレスを記入してください"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux があなたのリポジトリを読んでいます: ${GR_URL}"
    evidence "Git 上のソース" "url: ${GR_URL}
revision: ${GR_REV:-不明}"
  else
    fail "Flux がリポジトリ ${GR_URL} を読めません" \
         "flux get sources git を確認してください。多くの場合、アドレスのタイプミス、プライベートリポジトリ、または別のブランチが原因です"
    evidence "ソースのエラー" "${GR_MSG:-メッセージなし}"
  fi
fi

# --- 適用: Kustomization ----------------------------------------------
# ここで確認するのは適用の事実ではなく、それがなければラボが意味を失う仕組みの3つの性質だ:
# 適用されたリビジョンが Git と一致すること、リコンサイルが一時停止されていないこと、
# リポジトリから消えたものの削除が有効になっていること。
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "クラスタに Kustomization 型がありません" \
       "Flux が kustomize-controller なしでインストールされています — 両方のコンポーネントで再インストールしてください"
else
  KS_READY="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  KS_MSG="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  KS_REV="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.status.lastAppliedRevision}')"
  KS_SUSPEND="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.suspend}')"
  KS_PRUNE="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.prune}')"
  KS_INTERVAL="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.interval}')"

  if [ -z "$KS_REV" ] && [ -z "$KS_READY" ]; then
    fail "flux-system に ${KUSTOMIZATION} という名前の Kustomization が見つかりません" \
         "flux/kustomization.yaml を適用してください"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux が Git の状態を適用しました。リビジョン ${KS_REV}"
    evidence "適用されたリビジョン" "$KS_REV"
  else
    fail "Flux が Git の状態を適用できませんでした" \
         "flux get kustomizations と kubectl describe kustomization ${KUSTOMIZATION} -n flux-system を確認してください"
    evidence "適用のエラー" "${KS_MSG:-メッセージなし}"
  fi

  # 一時停止された Flux はインストール済みに見えるが、何もしない。これはラボの利点を
  # 一つも得ないまま「合格」する主な方法だ。
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "リコンサイルが一時停止されています (suspend: true) — Flux はクラスタを監視していません" \
         "元に戻してください: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "リコンサイルが有効です: Git との差分は自動的に修正されます。間隔 ${KS_INTERVAL:-デフォルト}"
  fi

  # これは fail ではなく warn だ: prune がなくてもクラスタは Git から管理され、ラボは合格する。
  # ただし記述が一方向になる — ファイルを削除してもクラスタでは何も削除されない。
  if [ "$KS_PRUNE" = "true" ]; then
    ok "Git から消えたものの削除が有効です (prune)"
  else
    warn "prune が無効です — リポジトリから削除されたものはクラスタで稼働し続けます" \
         "flux/kustomization.yaml に prune: true を設定してください。さもないと Git は状態の半分しか記述しません"
  fi
fi

# --- クラスタ内のオブジェクトは手動で適用されたのではなく Flux に属する ---------
# これはラボの中核となるチェックで、存在ではなく由来に関するものだ。アプリケーションは
# どちらの場合もクラスタに存在する: Flux が持ち込んだ場合も、参加者が同じファイルを
# kubectl apply で手動適用した場合も。外見では区別できない — Deployment は同一だ。
# 区別するのは所有者ラベル: これはリポジトリの内容を適用するときに kustomize-controller だけが
# 付与する。手動で適用されたオブジェクトはそのラベルを得ない。
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "名前空間 ${NS_APP} に passes アプリケーションがありません" \
       "app/*.yaml を自分のリポジトリの apps フォルダに置き、push してリコンサイルを待ってください"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "クラスタ内のアプリケーションは手動適用ではなく Flux に属しています"
else
  fail "passes アプリケーションは存在しますが、Flux が作成したものではありません" \
       "それを削除し (kubectl delete ns ${NS_APP})、Flux に Git から再度デプロイさせてください"
fi

# --- アプリケーションが実際に応答する --------------------------------------
# クラスタ内のオブジェクトと稼働中のサービスは別物だ: Deployment が作成されていても、
# Pod がループでクラッシュしていることがある。だからクラスタ内部に入り、サービスを
# その内部名で要求する — 隣接するアプリケーションがそれに到達するのと同じ経路で。
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'Пропуск'; then
  ok "«Пропуск» サービスがクラスタ内部で HTTP 応答しています (稼働中のレプリカ: ${PODS_READY})"
else
  fail "«Пропуск» サービスが passes.${NS_APP}.svc.cluster.local で応答しません" \
       "kubectl get pods -n ${NS_APP} と kubectl logs -n ${NS_APP} deploy/passes を確認してください"
fi

# ページ内の Pod 名は実際に稼働しているレプリカと一致すべきだ: これにより、
# 応答しているのがキャッシュされた回答や偶然同じ名前を取った別のサービスではなく、
# まさにクラスタで見える Pod だと分かる。不一致は fail ではなく warn だ:
# レプリカは2つのリクエストの間に再作成されえて、それは参加者の誤りではない。
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "ページを返したのは実際に存在する Pod ${SERVED_POD} です"
  evidence "サービスのレプリカ" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "応答内の Pod ${SERVED_POD} が稼働中のものの中に見つかりません" \
       "おそらくレプリカが2つのリクエストの間に再作成されました — もう一度チェックを実行してください"
fi

# --- あなたのリポジトリのクローンにおける変更履歴 ----------------------------
# 任意の部分: スクリプトは指示されるまでクローンがどこにあるか知らない。
# ここで確認するのはロールバックの方法だ。kubectl rollout undo でもクラスタは
# 以前のバージョンに戻るが、Git はそれを知らず、次のリコンサイルが悪い
# 変更を戻してしまう。だから履歴の中に revert を探す — ロールバックは真実の宿る
# 場所で行われる。そしてクラスタに適用されたリビジョンがあなたの HEAD と一致するか確認する:
# コミットして push を忘れるのはよくあることで、外からは「Flux が固まった」ように見える。
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "リポジトリの履歴は確認されませんでした: LAB_REPO 変数が設定されていません" \
       "これも確認するには: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "${REPO} にリポジトリのクローンがありません" \
       "git clone した先のフォルダを指定してください"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "履歴に git revert によるロールバックがあります — 悪い変更は真実の宿る場所で取り消されました"
    evidence "変更履歴" "$LOG"
  else
    fail "直近のコミットに revert が1つもありません" \
         "kubectl rollout undo ではなく、git revert --no-edit HEAD で悪い変更をロールバックして push してください"
  fi

  # クラスタに適用されたものはブランチの最新コミットと一致すべきだ。
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "クラスタではあなたのブランチにあるものがそのまま稼働しています (コミット ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "クラスタのコミット (${KS_REV:-不明}) がローカルの HEAD (${HEAD_SHA}) と異なります" \
         "ローカルのコミットが送信されている (git push) ことを確認し、リコンサイルの間隔を待ってください"
  fi
fi

finish
