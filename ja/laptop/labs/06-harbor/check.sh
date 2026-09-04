#!/usr/bin/env bash
# ラボ6のチェック: アプリケーションが自分専用のプライベートレジストリからクラスターにデプロイされる。
#
# 「Harborが作成された」ことではなく、連鎖全体を確認する。レジストリが自身のAPIで応答し、
# マニフェスト内のイメージがまさにそのレジストリに置かれ、クラスターがその同じアドレスへの認証情報を持ち、
# そのイメージのPodが実際に動作して応答すること。
#
# クラスターが2つあること、これがこのスクリプトが近隣のものより複雑に見える主な理由だ。
# KUBECONFIG はアプリケーションが動くあなたのlabクラスター。COZY_KUBECONFIG は
# あなたのテナント内にマネージドHarborサービスが存在する Cozystack 管理クラスター。
# 両方を1つのコマンドでは問い合わせられないので、以下にはkubectlを呼ぶ2つの異なる方法がある。
#
# あなたがラボのフォルダから実行する。何も変更せず、見て確認しレポートを出力するだけ:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/workshop
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="ラボ6 · 自分専用のプライベートイメージレジストリ"
# 全ラボ共通の土台: ok / fail / warn / evidence / finish と環境チェック。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# クラスターアクセスファイルもテナント番号もなければ確認するものがない — すぐに終了する。
need_kubeconfig
need_tenant

APP="passes-api"
# 管理クラスター上のテナント名前空間: 名前は接頭辞 tenant- とあなたの番号から作られる、
# つまり tenant-workshopXX。番号は環境から取得されるので、
# スクリプトの本文に手で埋め込む必要はない。
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# kubectlを呼ぶ2つの方法: kget はあなたのlabクラスターへ、cozy は管理クラスターへ行く。
# エラーは意図的に握りつぶす。ここでのオブジェクト欠如は障害ではなく想定された結果の1つであり、
# 以下で明快なアドバイス付きの別分岐で処理される。
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 管理クラスター上のマネージドHarborサービス -----------------------------
# 任意の部分: テナントのkubeconfigがなくてもラボは確認可能だが、
# プラットフォーム側からはサービスが見えない。
#
# 「コマンドが動かなかった」ケースは別途捕捉する。テナント内のロールがアプリケーションの
# 閲覧を許可しない場合がある。これは参加者のミスではなくチェックを失敗させる理由でもないので、
# ここは warn — 「見なかった」であり、fail — 「間違って行った」ではない。コマンドのエラーと
# 空の応答は意図的に区別する。空のリストはHarborがそもそも作成されていないことを意味する。
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "テナントのkubeconfig ${COZY_KUBECONFIG} が見つからない — Harborの状態は確認されなかった" \
       "パスを指定してください: export COZY_KUBECONFIG=~/.kube/workshop"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "テナント ${TENANT_NS} のHarborアプリケーションを閲覧できなかった" \
         "テナント内のロールがこのコマンドを許可していない可能性がある — これはラボのエラーではない。他はすべて以下で確認される"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "テナント ${TENANT_NS} にHarborアプリケーションが1つもない" \
         "ダッシュボードで作成してください: アプリケーションを作成 -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "マネージドHarborサービス「${HARBOR_NAME}」は準備完了"
    else
      warn "Harbor「${HARBOR_NAME}」は存在するが、準備完了を報告していない" \
           "ダッシュボードでその状態を確認してください。Harborの起動には5〜10分かかり、テナントにオブジェクトストレージがないと全く起動しない"
    fi
    evidence "テナント内のHarborアプリケーション" "$HARBOR_LIST"
    # 認証情報のシークレットを読もうとはしない。テナントはこのシークレットを読めるが、
    # いずれにせよパスワードはレポートに不要だ。
  fi
fi

# --- アプリケーションがどこからイメージを取得するか -------------------------
# ラボの狙いは、イメージがインターネットからではなく、あなたのレジストリから来ること。これは
# マニフェスト内のイメージ名で確認する。名前のスラッシュより前の最初の部分がレジストリ
# アドレスだ。そこにドットもコロンもなければアドレスは全く存在せず、クラスターは黙って
# Docker Hub にイメージを取りに行く — つまりセキュリティが禁じたまさにその場所へ。
# HARBOR-HOST のプレースホルダーと既知の公開レジストリは別分岐で捕捉する。
# 形式上アドレスは所定の位置にあるが、ラボの要件は満たされておらず、アドバイスは各ケースで異なる。
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "labクラスターにアプリケーション ${APP} がない" \
       "自分のHarborのアドレスを埋め込んだ passes.yaml を適用してください"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # レジストリアドレスのように見える
    *) REGISTRY="" ;;          # アドレスがない — つまりイメージは Docker Hub から取得される
  esac

  if [ -z "$REGISTRY" ]; then
    fail "イメージ ${IMAGE} はあなたのものではなく公開レジストリから取得されている" \
         "イメージ名の最初の部分はあなたのHarborのアドレスであるべきだ"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "マニフェストにプレースホルダーのアドレス HARBOR-HOST が残っている" \
         "自分のHarborのアドレスを埋め込んでください: sed -i 's|HARBOR-HOST|harbor.あなたのドメイン|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "イメージが公開レジストリ ${REGISTRY} から取得されている" \
         "セキュリティはプライベートレジストリを求めた — イメージをビルドして自分のHarborにpushしてください"
  else
    ok "アプリケーションはあなたのレジストリから起動している: ${REGISTRY}"
    evidence "アプリケーションのイメージ" "$IMAGE"
  fi
fi

# --- レジストリが実際に動作している -----------------------------------------
# マニフェスト内のアドレスが正しく書かれていても、そこにレジストリが存在しないことがある。Harborは
# 瞬時には起動せず、ドメインのタイプミスも見た目は全く同じだ。だから
# そのAPIを叩いて「pong」応答を待つ — これはそこにあるのが確かにHarborであり、
# 他人のサイトでもロードバランサーのスタブでもないことを裏付ける。
if [ -z "$REGISTRY" ]; then
  : # すでに上で報告済み
elif ! command -v curl >/dev/null 2>&1; then
  warn "curlユーティリティがない — レジストリの到達性は確認されなかった" \
       "ブラウザで https://${REGISTRY} を開いてください。そこにHarborのインターフェースがあるはずだ"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","不明"))' 2>/dev/null)"
    ok "レジストリはAPIで応答している: https://${REGISTRY} (Harbor ${VER:-バージョン不明})"
    evidence "レジストリ" "https://${REGISTRY}
API ping: ${PING}
Harborバージョン: ${VER:-不明}"
  else
    fail "レジストリ https://${REGISTRY} は /api/v2.0/ping への要求に応答しない" \
         "アドレスとダッシュボード内のHarborアプリケーションの状態を確認してください"
  fi
fi

# --- クラスターがアクセス認証情報を持っている ------------------------------
# シークレットがマニフェストで参照されているだけでは不十分だ — 重要なのは、それがイメージの取得元で
# あるまさにそのレジストリへの認証情報を持っていること。最もよくあるラボのミスは正しく見える。
# シークレットは作成され、マニフェストで名前を付けられているが、その中のアドレスが違う
# (余分な https://、ポート、別のホスト名) と、kubeletはそれを適用しない。
# だからシークレットの中身を展開し、名前ではなくアドレスを比較する。
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # アプリケーションがない、上で報告済み
elif [ -z "$PULL_SECRETS" ]; then
  fail "マニフェスト ${APP} に imagePullSecret が1つも指定されていない" \
       "プライベートレジストリのイメージは認証情報なしではダウンロードされない: imagePullSecrets を追加してください、passes.yaml 参照"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # 設定はpythonで解析する: base64 -d は macOS と Linux で挙動が異なり、
    # パスワードはレポートに出力してはいけない — アドレスのリストだけを取る。
    SERVERS="$(kget secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' \
      | python3 -c 'import sys,json,base64
raw = sys.stdin.read().strip()
try:
    cfg = json.loads(base64.b64decode(raw))
    print(" ".join(cfg.get("auths", {}).keys()))
except Exception:
    pass' 2>/dev/null)"
    if [ -n "$REGISTRY" ] && printf '%s' "$SERVERS" | grep -q "$REGISTRY"; then
      SECRET_OK="$s"
      break
    fi
  done

  if [ -n "$SECRET_OK" ]; then
    ok "クラスターはシークレット ${SECRET_OK} に ${REGISTRY} への認証情報を持っている (パスワード: <非表示>)"
  else
    fail "指定されたシークレット (${PULL_SECRETS}) のいずれも ${REGISTRY:-あなたのレジストリ} への認証情報を含んでいない" \
         "次のように作成してください: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-アドレス} --docker-username=admin --docker-password=..."
  fi
fi

# --- Podが実際に起動した ----------------------------------------------------
# ImagePullBackOff と ErrImagePull の状態は別途処理する。これはラボが意図的に見せている
# まさにその失敗であり、参加者が一般的な「Podが動いていない」ではなく、それを一目で見分けられる
# ことが重要だ。本当の原因は証拠として出力する —
# レジストリの障害でもイメージ名のタイプミスでもPodの状態は同じだからだ。
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "稼働中のアプリケーションのレプリカ: ${RUNNING}"
  evidence "アプリケーションのPod" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "イメージがダウンロードされない: ${BADSTATE}" \
       "これはレジストリへのアクセス拒否かイメージ名のタイプミスだ。本当の原因は kubectl describe pod -l app=passes-api で示される"
  evidence "失敗の原因" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "稼働中のアプリケーションのレプリカが1つもない (状態: ${BADSTATE:-Podがない})" \
       "kubectl describe pod -l app=passes-api を見てください"
fi

# 最も診断が難しいラボのエラーへの別チェック: イメージが ARM 向けにビルドされ、
# クラスターのノードは x86 だという状況。すべて正しく見える — イメージはビルドされ、
# レジストリにpushされ、ノードにダウンロードされた — が、プロセスが起動しない。周囲の何も
# プロセッサアーキテクチャを示唆せず、唯一の手がかりはPodのログにある。だから
# それを別チェックで見て、原因を直接名指しする。
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "イメージが別のプロセッサアーキテクチャ向けにビルドされている" \
       "フラグ付きで再ビルドしてください: docker build --platform linux/amd64 -t ${IMAGE} app/ して再度pushする"
fi

# --- アプリケーションが実質的に応答する -------------------------------------
# Podが稼働していても、まだ動作するサービスを意味しない。クラスター内に入り、内部名で
# アプリケーションに要求し、応答からPod名を読む。実際に稼働中のPodと一致すれば —
# 応答しているのはまさに我々がデプロイしたアプリケーションであり、偶然そのアドレスを占めた
# 別のものではない。不一致は fail ではなく warn だ。
# レプリカが2つの要求の間に再作成された可能性があり、参加者のミスではないからだ。
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "${APP} という名前の Service がない" \
       "それは passes.yaml に記述されている — Deployment だけでなくファイル全体を適用してください"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "サービス ${APP} が期待されたJSONを返さなかった" \
         "kubectl logs -l app=passes-api を見て、Service のポートがアプリケーションのポートと一致していることを確認してください"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "サービスはJSONで応答し、応答は実際に稼働中のPod ${SERVED_POD} から来た"
    evidence "サービスの応答" "$BODY"
  else
    warn "サービスは稼働中のものにないPod ${SERVED_POD} の名前で応答した" \
         "おそらくレプリカが要求の間に再作成された — もう一度チェックを実行してください"
  fi
fi

finish
