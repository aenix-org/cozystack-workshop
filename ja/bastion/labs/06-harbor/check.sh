#!/usr/bin/env bash
# ラボ6のチェック: アプリケーションが自分専用のプライベートレジストリからクラスタに届く。
#
# 「Harborが作成された」ではなく、連鎖全体を確認する: レジストリが自分のAPIで応答し、
# マニフェスト内のイメージがまさにそこに置かれ、クラスタがその同じアドレスへの認証情報を持ち、
# このイメージのPodが実際に動作して応答すること。
#
# 2つのクラスタがあり、これがこのスクリプトが隣接するものより複雑に見える主な理由:
# KUBECONFIG はアプリケーションが動くあなたのlabクラスタ、COZY_KUBECONFIG は
# あなたのテナント内にマネージドHarborサービスが存在するCozystack管理クラスタ。
# 1つのコマンドで両方を問い合わせることはできないので、以下にkubectlを呼ぶ2通りの方法がある。
#
# あなたが、ラボのフォルダから実行する。何も変更せず、状態を確認してレポートを出力するだけ:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/config
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="ラボ6 · 自分専用のプライベートイメージレジストリ"
# すべてのラボ共通のラッパー: ok / fail / warn / evidence / finish と環境チェック。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# クラスタアクセスファイルとテナント番号がなければ確認するものがない — すぐに終了する。
need_kubeconfig
need_tenant

APP="passes-api"
# 管理クラスタ上のテナント名前空間: 名前はプレフィックス tenant- とあなたの番号から
# 組み立てられる、つまり tenant-workshopXX。番号は環境から取得されるので、
# スクリプトのテキストに手で埋め込む必要はない。
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# kubectlを呼ぶ2通りの方法: kget はあなたのlabクラスタへ、cozy は管理クラスタへ。
# エラーは意図的に抑制している: ここでのオブジェクト不在は障害ではなく想定される
# 結果の1つであり、以下の別ブランチで明確な助言とともに処理される。
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 管理クラスタ上のマネージドHarborサービス -------------------------------
# 任意の部分: テナントのkubeconfigがなくてもラボは確認可能だが、
# プラットフォーム側からサービスを見ることはできない。
#
# 「コマンドが動作しなかった」ケースを別途捕捉する: テナント内のロールが
# アプリケーションの閲覧を許可していない場合がある。これは参加者の誤りではなく
# チェックを失敗させる理由でもないので、ここは warn —「見られなかった」であり、
# fail —「間違って行った」ではない。コマンドエラーと空の応答は意図的に区別する:
# 空のリストはHarborがまったく作成されていないことを意味する。
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "テナントのkubeconfig ${COZY_KUBECONFIG} が見つからない — Harborの状態は確認されなかった" \
       "パスを指定してください: export COZY_KUBECONFIG=~/.kube/config"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "テナント ${TENANT_NS} 内のHarborアプリケーションを閲覧できなかった" \
         "テナント内のロールがこのコマンドを許可していない可能性がある — これはラボの誤りではない。他はすべて以下で確認される"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "テナント ${TENANT_NS} にHarborアプリケーションが1つもない" \
         "ダッシュボードで作成してください: アプリケーションを作成 -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "マネージドHarborサービス «${HARBOR_NAME}» は準備完了"
    else
      warn "Harbor «${HARBOR_NAME}» は存在するが、準備完了を報告していない" \
           "ダッシュボードでその状態を確認してください。Harborの起動には5〜10分かかり、テナントにオブジェクトストレージがなければまったく起動しない"
    fi
    evidence "テナント内のHarborアプリケーション" "$HARBOR_LIST"
    # 認証情報のシークレットは読もうとしない: テナントはこのシークレットを読める
    # (プラットフォームは各アプリケーションの認証情報ごとに別のルールを作る)が、
    # いずれにせよレポートにパスワードは不要だ。
  fi
fi

# --- アプリケーションはどこからイメージを取得するか ------------------------
# ラボの要点は、イメージがインターネットからではなくあなたのレジストリから来たこと。これは
# マニフェスト内のイメージ名で確認する: スラッシュまでの名前の最初の部分がレジストリのアドレス。
# そこにドットもコロンもなければアドレスはまったく存在せず、クラスタは黙って
# Docker Hubへイメージを取りに行くことになる — つまりまさにセキュリティ部門が禁じた場所へ。
# HARBOR-HOST プレースホルダと既知の公開レジストリは別々のブランチで捕捉する:
# 形式上アドレスは所定の位置にあるが、ラボの要件は満たされておらず、助言はケースごとに異なる。
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "labクラスタにアプリケーション ${APP} がない" \
       "自分のHarborのアドレスを埋め込んで passes.yaml を適用してください"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # レジストリのアドレスらしい
    *) REGISTRY="" ;;          # アドレスがない — イメージはDocker Hubから取得される
  esac

  if [ -z "$REGISTRY" ]; then
    fail "イメージ ${IMAGE} は公開レジストリから取得されている、あなたのものではない" \
         "イメージ名の最初の部分はあなたのHarborのアドレスでなければならない"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "マニフェストにプレースホルダのアドレス HARBOR-HOST が残っている" \
         "自分のHarborのアドレスを埋め込んでください: sed -i 's|HARBOR-HOST|harbor.yourdomain|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "イメージは公開レジストリ ${REGISTRY} から取得されている" \
         "セキュリティ部門はプライベートレジストリを求めた — イメージをビルドして自分のHarborにプッシュしてください"
  else
    ok "アプリケーションはあなたのレジストリから起動する: ${REGISTRY}"
    evidence "アプリケーションのイメージ" "$IMAGE"
  fi
fi

# --- レジストリが実際に動作している ----------------------------------------
# マニフェスト内のアドレスは正しく書かれているかもしれないが、その先にレジストリがない場合がある: Harborは
# 瞬時には起動せず、ドメインのタイポもまったく同じに見える。そこで
# そのAPIを叩いて「pong」の応答を待つ — これはそこが確かにHarborであり、
# 他人のサイトでもロードバランサのスタブでもないことを裏付ける。
if [ -z "$REGISTRY" ]; then
  : # 上ですでに報告済み
elif ! command -v curl >/dev/null 2>&1; then
  warn "curlユーティリティがない — レジストリの到達性は確認されなかった" \
       "ブラウザで https://${REGISTRY} を開いてください。そこにHarborのインターフェースがあるはず"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","不明"))' 2>/dev/null)"
    ok "レジストリがAPIで応答している: https://${REGISTRY} (Harbor ${VER:-バージョン不明})"
    evidence "レジストリ" "https://${REGISTRY}
API ping: ${PING}
Harborバージョン: ${VER:-不明}"
  else
    fail "レジストリ https://${REGISTRY} が /api/v2.0/ping リクエストに応答しない" \
         "アドレスとダッシュボードのHarborアプリケーションの状態を確認してください"
  fi
fi

# --- クラスタがアクセス認証情報を持っている --------------------------------
# シークレットがマニフェストで参照されているだけでは不十分 — 重要なのは、それが
# イメージの取得元となるまさにそのレジストリの認証情報を持っていること。最もよくあるラボの誤りは
# 正しく見える: シークレットは作成され、マニフェストで名指しされているが、その中のアドレスが違う
# (余分な https://、ポート、別のホスト名)ため、kubeletは適用しない。
# そこでシークレットの中身を展開し、名前ではなくアドレスを比較する。
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # アプリケーションがない、上で報告済み
elif [ -z "$PULL_SECRETS" ]; then
  fail "${APP} のマニフェストに imagePullSecret が1つも指定されていない" \
       "認証情報なしにプライベートレジストリのイメージは取得されない: imagePullSecrets を追加してください、passes.yaml を参照"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # 設定はpythonで解析する: base64 -d はmacOSとLinuxで挙動が異なり、
    # パスワードをレポートに出力してはならない — アドレスのリストだけを取得する。
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
    ok "クラスタはシークレット ${SECRET_OK} に ${REGISTRY} への認証情報を持っている (パスワード: <非表示>)"
  else
    fail "指定されたシークレット (${PULL_SECRETS}) のいずれも ${REGISTRY:-あなたのレジストリ} への認証情報を含んでいない" \
         "次のように作成してください: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-アドレス} --docker-username=admin --docker-password=..."
  fi
fi

# --- Podが実際に起動した ---------------------------------------------------
# ImagePullBackOff と ErrImagePull の状態を別途処理する: これはまさにラボが意図的に
# 見せる失敗であり、参加者がそれを一目で見分けられることが重要で、一般的な
# 「Podが動かない」を受け取るのではない。本当の原因はエビデンスとして出力する —
# レジストリの障害でもイメージ名のタイポでもPodの状態は同じだからだ。
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "動作中のアプリケーションのコピー数: ${RUNNING}"
  evidence "アプリケーションのPod" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "イメージが取得されていない: ${BADSTATE}" \
       "これはレジストリへのアクセス拒否かイメージ名のタイポ。本当の原因は kubectl describe pod -l app=passes-api が示す"
  evidence "失敗の原因" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "動作中のアプリケーションのコピーが1つもない (状態: ${BADSTATE:-Podがない})" \
       "kubectl describe pod -l app=passes-api を確認してください"
fi

# ラボで最も診断が難しい誤りへの個別チェック: イメージがARM向けにビルドされ、
# クラスタのノードがx86の場合。すべて正しく見える — イメージはビルドされ、レジストリに
# 送られ、ノードに取得された — が、プロセスが起動しない。周りには何もプロセッサの
# アーキテクチャを示唆するものがなく、唯一の手がかりはPodのログにあるので、
# それを個別チェックで確認し、原因を直接名指しする。
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "イメージが別のプロセッサアーキテクチャ向けにビルドされている" \
       "フラグ付きで再ビルドしてください: docker build --platform linux/amd64 -t ${IMAGE} app/ してから再度プッシュ"
fi

# --- アプリケーションが実質的に応答する ------------------------------------
# 起動したPodはまだ動作するサービスを意味しない。クラスタ内部に入り、
# 内部名でアプリケーションにリクエストし、応答からPod名を読む。実際に
# 動作中のPodと一致すれば — 応答はまさに我々がデプロイしたアプリケーションから来ており、
# このアドレスをたまたま占有した別の何かではない。不一致は fail ではなく warn:
# 2つのリクエストの間にコピーが再作成された可能性があり、参加者のせいではない。
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "名前 ${APP} のServiceがない" \
       "それは passes.yaml に記述されている — Deploymentだけでなくファイル全体を適用してください"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "サービス ${APP} が期待されるJSONを返さなかった" \
         "kubectl logs -l app=passes-api を確認し、Serviceのポートがアプリケーションのポートと一致することを確かめてください"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "サービスがJSONで応答し、応答は実際に動作中のPod ${SERVED_POD} から来た"
    evidence "サービスの応答" "$BODY"
  else
    warn "サービスはPod ${SERVED_POD} を名乗って応答したが、それは動作中のものの中にない" \
         "おそらくリクエストの間にコピーが再作成された — チェックをもう一度実行してください"
  fi
fi

finish
