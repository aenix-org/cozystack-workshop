#!/usr/bin/env bash
# ラボ5のチェック: クラスタの状態はGitから届き、同期（reconciliation）によって維持される。
#
# あなた自身が、`lab` クラスタに対して、ラボのフォルダから実行します:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# 何も変更しません。見るだけで、レポートを表示します: 何を確認したか、何が通ったか、
# 何が通らなかったか、そして添付された証跡。
#
# 確認するのは「Fluxがインストールされている」ではなく「仕組みが動いている」です: ソースが読まれ、
# 適用されたものがFluxに属し、サービスが応答し、同期が無効化されていない。インストール済みだが
# 一時停止されたFluxは、ラボの意味を取りこぼしたまま通過する最も一般的な方法です。

LAB_NAME="05-gitops"
LAB_TITLE="ラボ5 · Git上のインフラ"
# すべてのラボ共通の土台: ここから ok / fail / warn / evidence / finish と環境チェックが
# 提供されます。パスはこのファイルの場所を基準に解決されるので、スクリプトは
# どのフォルダからでも実行できます。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# クラスタへのアクセスファイルがなければ確認するものがありません。明確な理由とともにすぐに終了します。
need_kubeconfig

# このラボが作成する名前。一箇所にまとめてあります: 参加者がオブジェクトを別の名前に
# した場合は、スクリプト全体で名前を探すのではなく、ここを編集します。
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# オブジェクトやCRDが存在しなくても失敗せずに、オブジェクトのフィールドを読む。
kget() { kubectl get "$@" 2>/dev/null; }

# --- Fluxのサービス -----------------------------------------------------------
# 見るのは「ポッドが存在する」ではなく「Ready状態のレプリカが少なくとも1つある」です: ポッドは
# ノードにメモリがなくPendingでぶら下がったまま、get pods の出力には現れることがあります。
# 両方のサービスが必須で、作業を分担します: source-controller がリポジトリをダウンロードし、
# kustomize-controller がダウンロードしたものを適用します。2つ目がなければ何もクラスタに届きません。
if ! kget namespace flux-system >/dev/null; then
  fail "クラスタに flux-system 名前空間がありません" \
       "Fluxがインストールされていません: flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "Fluxのサービスが動作しています: source-controller と kustomize-controller"
    evidence "Fluxのポッド" "$(kget pods -n flux-system -o wide)"
  else
    fail "Fluxのサービスが動作していません:${FLUX_BAD}" \
         "kubectl get pods -n flux-system を確認してください。小さなノードではメモリが不足していることがあります"
  fi
fi

# --- ソース: GitRepository ------------------------------------------------
# 3つの異なる結果があり、混同してはいけません: オブジェクトがまったく存在しない; オブジェクトは
# あるがまだアドレスのプレースホルダが残っている; オブジェクトがあり本物のアドレスだが、Fluxが
# リポジトリを読めなかった。それぞれで助言が異なるので、分岐も異なります。
#
# 成功の兆候は status.conditions から取ります。これはオブジェクトの存在からの推測ではなく、
# FluxがGitに到達しようとした後に自分自身について報告する内容です。
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "クラスタに GitRepository 型がありません" \
       "Fluxがインストールされていないか、source-controller なしでインストールされています"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "flux-system に ${GITREPO} という名前の GitRepository が見つかりません" \
         "自分のリポジトリのアドレスを入れて flux/gitrepository.yaml を適用してください"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "GitRepository にプレースホルダのアドレスが残っています" \
         "flux/gitrepository.yaml を開いて自分のGitHubリポジトリのアドレスを記入してください"
  elif [ "$GR_READY" = "True" ]; then
    ok "Fluxがあなたのリポジトリを読んでいます: ${GR_URL}"
    evidence "Git上のソース" "url: ${GR_URL}
revision: ${GR_REV:-不明}"
  else
    fail "Fluxがリポジトリ ${GR_URL} を読めません" \
         "flux get sources git を確認してください。多くの場合はアドレスのタイプミス、プライベートリポジトリ、または別のブランチです"
    evidence "ソースのエラー" "${GR_MSG:-メッセージなし}"
  fi
fi

# --- 適用: Kustomization ----------------------------------------------
# ここで確認するのは適用の事実ではなく、これがなければラボが意味を失う仕組みの3つの性質です:
# 適用されたリビジョンがGitと一致すること、同期が一時停止されていないこと、
# リポジトリから消えたものの削除が有効になっていること。
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "クラスタに Kustomization 型がありません" \
       "Fluxが kustomize-controller なしでインストールされています。両方のコンポーネントで再インストールしてください"
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
    ok "FluxがGitの状態を適用しました。リビジョン ${KS_REV}"
    evidence "適用されたリビジョン" "$KS_REV"
  else
    fail "FluxがGitの状態を適用できませんでした" \
         "flux get kustomizations と kubectl describe kustomization ${KUSTOMIZATION} -n flux-system を確認してください"
    evidence "適用のエラー" "${KS_MSG:-メッセージなし}"
  fi

  # 一時停止されたFluxはインストール済みに見えて何もしません。これはラボの利点を1つも得ないまま
  # 「合格」する主な方法です。
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "同期が一時停止されています（suspend: true）— Fluxはクラスタを監視していません" \
         "元に戻してください: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "同期が有効です: Gitとのずれは自動的に修正されます。間隔 ${KS_INTERVAL:-デフォルト}"
  fi

  # これは fail ではなく warn です: prune がなくてもクラスタはGitから管理され、ラボは合格します。
  # ただし記述が一方通行になります — ファイルを削除してもクラスタからは何も削除されません。
  if [ "$KS_PRUNE" = "true" ]; then
    ok "Gitから消えたものの削除（prune）が有効です"
  else
    warn "prune が無効です — リポジトリから削除されたものはクラスタで動き続けます" \
         "flux/kustomization.yaml に prune: true を設定してください。さもないとGitは状態の半分しか記述しません"
  fi
fi

# --- クラスタ内のオブジェクトはFluxに属し、手で適用されたものではない ---------
# これはラボの中核となるチェックで、存在ではなく由来についてです。アプリケーションはどちらの場合も
# クラスタにあります: Fluxが持ち込んだときも、参加者が同じファイルを kubectl apply で手動適用した
# ときも。外見では区別できません — Deployment は同一です。
# 区別するのは所有者ラベルです: これはリポジトリの内容を適用するときに kustomize-controller だけが
# 付けます。手で適用されたオブジェクトはこのラベルを得ません。
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "${NS_APP} 名前空間に passes アプリケーションがありません" \
       "app/*.yaml を自分のリポジトリの apps フォルダに置き、push して、同期を待ってください"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "クラスタ内のアプリケーションはFluxに属し、手で適用されたものではありません"
else
  fail "passes アプリケーションは存在しますが、Fluxが作成したものではありません" \
       "それを取り除き（kubectl delete ns ${NS_APP}）、Fluxに再度Gitからデプロイさせてください"
fi

# --- アプリケーションが実際に応答する --------------------------------------
# クラスタ内のオブジェクトと動作するサービスは別物です: Deployment が作成されていても、ポッドが
# ループでクラッシュしていることがあります。だからクラスタの内側に入り、サービスをその内部名で
# リクエストします — 隣接するアプリケーションが到達するのと同じ経路です。
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'Пропуск'; then
  ok "«Пропуск» サービスがクラスタ内でHTTP経由で応答しています（動作中のレプリカ: ${PODS_READY}）"
else
  fail "«Пропуск» サービスが passes.${NS_APP}.svc.cluster.local で応答しません" \
       "kubectl get pods -n ${NS_APP} と kubectl logs -n ${NS_APP} deploy/passes を確認してください"
fi

# ページ内のポッド名は実際に動作しているレプリカと一致しなければなりません: これは応答が
# キャッシュされた答えや、たまたま同じ名前を取った別のサービスではなく、まさにクラスタで見ている
# ポッドから来ていることを示します。不一致は fail ではなく warn です: レプリカは2回のリクエストの
# 間に再作成された可能性があり、それは参加者のミスではありません。
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "ページを配信したのは実在するポッド ${SERVED_POD} です"
  evidence "サービスのレプリカ" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "応答に含まれるポッド ${SERVED_POD} が動作中のものの中に見つかりません" \
       "おそらくレプリカが2回のリクエストの間に再作成されました — もう一度チェックを実行してください"
fi

# --- あなたのリポジトリのクローンにおける変更履歴 ----------------------------
# 任意の部分: スクリプトは伝えられるまでクローンがどこにあるか知りません。
# ここで確認するのはロールバックの方法です。kubectl rollout undo でもクラスタは前のバージョンに
# 戻りますが、Gitはそれを知らず、次の同期でまさに悪い変更を戻します。だから履歴の中に revert を
# 探します — ロールバックは真実の在り処で行われます。そしてクラスタで適用されたリビジョンがあなたの
# HEAD と一致することを確認します: コミットしてpushを忘れるのはよくあることで、外からは
# 「Fluxが固まった」ように見えます。
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "リポジトリの履歴は確認されませんでした: 変数 LAB_REPO が設定されていません" \
       "それも確認するには: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "${REPO} にリポジトリのクローンがありません" \
       "git clone した先のフォルダを指定してください"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "履歴に git revert によるロールバックがあります — 悪い変更は真実の在り処で取り消されました"
    evidence "変更履歴" "$LOG"
  else
    fail "最近のコミットに revert が1つもありません" \
         "kubectl rollout undo ではなく、git revert --no-edit HEAD で悪い変更をロールバックしてpushしてください"
  fi

  # クラスタで適用されているものはブランチの最新コミットと一致しなければなりません。
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "クラスタではあなたのブランチにあるものがそのまま動作しています（コミット ${HEAD_SHA}）"
  elif [ -n "$HEAD_SHA" ]; then
    warn "クラスタのコミット（${KS_REV:-不明}）がローカルの HEAD（${HEAD_SHA}）と異なります" \
         "ローカルのコミットがpushされているか（git push）確認し、同期の間隔を待ってください"
  fi
fi

finish
