#!/usr/bin/env bash
# ラボ13のチェック: チャートとアプリケーション定義が管理者への引き渡し準備完了かどうか。
#
# このチェックは意図的にローカルで行う。テナントは ApplicationDefinition を適用でき
# ない(オブジェクトは cluster-scoped)ため、クラスター内で探しても意味がない:
# オブジェクトが存在しないのは参加者の責任ではない。参加者が責任を負う範囲を確認する:
# チャートがビルドでき、スキーマが機能し、定義がパースされチャートと整合していること。
#
# ラボのフォルダから実行:
#   cd labs/13-catalog && ./check.sh
# クラスターは必須ではない: KUBECONFIG がなければ 2 つのチェックはエラーではなく
# 警告付きでスキップされる。

LAB_NAME="13-catalog"
LAB_TITLE="ラボ13 · Cozystack カタログに自作アプリケーションを追加する"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- ツール -----------------------------------------------------------------
# helm がなければ確認できることは何もないので、スクリプトはここで即座に停止し、
# この先で同じ失敗を何十回も並べ立てないようにする。
if ! command -v helm >/dev/null 2>&1; then
  fail "このマシンに helm がありません" \
       "インストールしてください: brew install helm (macOS) または https://helm.sh/docs/intro/install/ — これがないとラボを確認できません"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm があります (${HELM_VER})"
evidence "helm のバージョン" "$HELM_VER"

# --- チャートの存在確認 ---------------------------------------------------------
# 「チャートが壊れている」と「スクリプトを違うフォルダから実行した」を区別する。後者の誤りは
# 前者より頻繁に起きるので、そのメッセージは別立てにすべきである。
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "${CHART} にチャートが見つかりません" \
       "スクリプトはラボのフォルダから実行してください: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- リンター ----------------------------------------------------------------
# helm lint はチャートをテキストとして読む: テンプレートのタイプミス、Chart.yaml の欠けた
# フィールド、存在しない値への参照を見つける。ここではクラスターまで到達しない。
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "チャートは helm lint を通過します"
  evidence "helm lint" "$LINT_OUT"
else
  fail "チャートが helm lint を通過しません" \
       "以下の出力を読んで、指摘されたファイルを修正してください: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- レンダリング ----------------------------------------------------------------
# 空の出力やコメントだけの出力はリンターをすり抜けるので、レンダリング結果の中に
# Deployment があることを確認し、そもそも何が生成されたのかを列挙する。
# ここで肝心なのは「コマンドが動いた」ことではなく「本物のオブジェクトが生成された」ことである。
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "チャートがレンダリングされ、オブジェクトが生成されます: ${KINDS}"
  evidence "チャートがレンダリングする内容" "$KINDS"
else
  fail "helm template が Deployment を 1 つも生成しませんでした" \
       "レンダリングのエラーを確認してください: helm template main chart"
  evidence "helm template の出力" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- チャートが本物のクラスターに受け入れられる ----------------------------------
# ラボ一式の中で唯一、マニフェストをテキストではなく本物のクラスターのスキーマと
# 照合するチェック。
#
# `helm lint` と `helm template` はテンプレートを確認するが、Kubernetes のスキーマは
# 確認しない: フィールドが誤った場所にあるマニフェストをすり抜けさせるが、クラスターは
# 拒否する。身をもって確認済み — volumes に誤って挿入した securityContext は両方を通過し、
# サーバー上でのみ破綻した。このチェックはチャートを実際に適用する場所で必要になる。
#
# なぜ lint と template が代わりにならないか:
#   helm lint      チャートの構造を見る: ファイルが揃っているか、テンプレートがパースできるか;
#   helm template  値を代入してテキストを生成する — だがそれがどんなフィールドで、そのような
#                  オブジェクトに存在しうるのかは分からないし、分かりようもない;
#   apply --dry-run=server はマニフェストを apiserver に送り、apiserver は型スキーマと
#                  admission コントロールを通して、何も作成せずに受け入れるかどうかを答える。
#                  そこから `unknown field` やポリシーによる拒否が生じる —
#                  まさに顧客先でチャートがつまずく点である。
# --dry-run=client フラグはこのチェックにならない: マニフェストを自分のマシンでパースするだけである。
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # 権限による拒否とスキーマによる拒否は別物であり、混同してはならない。テナント
  # アクセス(~/.kube/config)では Deployment と ConfigMap への権限はまったくないので、ここには
  # Forbidden が飛んでくる — そしてそれはチャートの品質について何も語らない。本質的なチェックは、
  # あなたが完全な所有者である `lab` クラスターへのアクセスでのみ可能である。
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "サーバー側のチャートチェックをスキップしました: 現在のアクセスでは実行できません" \
         "自分のクラスターへのアクセスで実行してください: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "クラスターがレンダリング済みチャートを拒否します" \
         "確認してください: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "サーバーの拒否" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "クラスターがレンダリング済みチャートを受け入れます — フィールドとその位置は正しい"
  fi
else
  warn "クラスターでのチャートチェックをスキップしました: アクセスがありません" \
       "helm template を kubectl apply --dry-run=server に通すため KUBECONFIG を設定してください"
fi

# --- パラメータが本当にマニフェストに届く -------------------------
# チャートがビルドされレンダリングされても、パラメータがどこにも代入されないことがある —
# 例えば、値をテンプレートに数値として直接書いてしまった場合。だから各パラメータを実地で確認する:
# 意図的に珍しい値を設定し、それが完成したマニフェストの中にあるか探す。
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "replicas パラメータがマニフェストに届きます (--set replicas=5 で replicas: 5 になる)"
else
  fail "replicas パラメータがマニフェストに届きません" \
       "templates/deployment.yaml に replicas: {{ .Values.replicas }} と書かれているべきです"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "external パラメータが Service のタイプを LoadBalancer に切り替えます"
else
  warn "external パラメータが Service のタイプを切り替えません" \
       "チャートの不具合ではないが、Cozystack カタログの慣習です: アプリケーションの external フィールドはまさに外部アクセスを意味します"
fi

# --- スキーマが本当に守っている ------------------------------------------
# 何も拒否しないスキーマは無意味である。スキーマが拒否することを確認する。
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "値スキーマが明らかに不正な値を拒否しません (replicas=abc が通過した)" \
       "values.yaml の隣に values.schema.json があり、その中で replicas が integer として宣言されているか確認してください"
else
  ok "値スキーマが誤った型を拒否します (replicas=abc は通過しない)"
fi

# --- ApplicationDefinition: 必須フィールド ------------------------------
# 参加者は定義を適用できないので、apiserver の拒否も目にしない。
# だから必須フィールドをここで数え上げる: どれか 1 つでも欠ければ管理者は自分の側で拒否を
# 受け取り、その原因を解明する羽目になるのはファイルの作者である。
if [ ! -f "$APPDEF" ]; then
  fail "${APPDEF} が見つかりません" \
       "ファイルはチャートの隣にあるべきです; ラボのリポジトリから取得してください"
else
  MISSING=""
  # YAML をパースせず、キーを行単位で探す: PyYAML はどのマシンにもあるわけではなく、
  # ファイル 1 つを確認するために依存を持ち込む価値はない。
  check_key() {
    grep -Eq "$1" "$APPDEF" || MISSING="$MISSING $2"
  }
  check_key '^kind:[[:space:]]+ApplicationDefinition[[:space:]]*$' 'kind: ApplicationDefinition'
  check_key '^apiVersion:[[:space:]]+cozystack\.io/v1alpha1[[:space:]]*$' 'apiVersion: cozystack.io/v1alpha1'
  check_key '^[[:space:]]{4}kind:[[:space:]]+\S+' 'application.kind'
  check_key '^[[:space:]]{4}plural:[[:space:]]+\S+' 'application.plural'
  check_key '^[[:space:]]{4}singular:[[:space:]]+\S+' 'application.singular'
  check_key '^[[:space:]]{4}openAPISchema:' 'application.openAPISchema'
  check_key '^[[:space:]]{4}prefix:[[:space:]]+\S+' 'release.prefix'
  check_key '^[[:space:]]{6}kind:[[:space:]]+(OCIRepository|HelmChart|ExternalArtifact)' 'release.chartRef.kind'
  check_key '^[[:space:]]{4}category:[[:space:]]+\S+' 'dashboard.category'
  check_key '^[[:space:]]{4}icon:[[:space:]]+\S+' 'dashboard.icon'

  if [ -z "$MISSING" ]; then
    ok "ApplicationDefinition に必須フィールドがすべて揃っています"
  else
    fail "ApplicationDefinition にフィールドが不足しています:${MISSING}" \
         "README の解説と照合してください — どれか 1 つでも欠ければ管理者は適用時に拒否を受け取ります"
  fi

  # --- 定義内のスキーマがパースでき、チャートのスキーマと一致する ---------
  # これらは同じものの 2 つの別コピーであり、両者の間に連携はまったくない。
  # ずれると — ダッシュボードのフォームはチャートが期待するのとは違うフィールドを表示する。
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "ApplicationDefinition の openAPISchema が空です" \
         "そこに chart/values.schema.json の内容を 1 行で貼り付けてください"
  else
    CMP="$(SCHEMA_LINE="$SCHEMA_LINE" python3 - "$CHART/values.schema.json" <<'PY' 2>&1
import os, sys, json
try:
    inline = json.loads(os.environ["SCHEMA_LINE"])
except Exception as e:
    print("BADJSON %s" % e); raise SystemExit
try:
    chart = json.load(open(sys.argv[1]))
except Exception as e:
    print("NOCHART %s" % e); raise SystemExit
a = sorted((inline.get("properties") or {}).keys())
b = sorted((chart.get("properties") or {}).keys())
if a == b:
    print("SAME %s" % ",".join(a))
else:
    only_def = sorted(set(a) - set(b))
    only_chart = sorted(set(b) - set(a))
    print("DIFF 定義のみ: %s | チャートのみ: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "定義内のスキーマがパースでき、チャートのスキーマと一致します (${CMP#SAME })"
        evidence "アプリケーションのパラメータ" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "定義内のスキーマがチャートのスキーマと食い違っています: ${CMP#DIFF }" \
             "両者を一致させてください: openAPISchema の内容は chart/values.schema.json を 1 行にしたものです"
        ;;
      BADJSON*)
        fail "openAPISchema が JSON としてパースできません: ${CMP#BADJSON }" \
             "スキーマは 'openAPISchema: |-' の下に正しい JSON を 1 行で置く必要があります"
        ;;
      *)
        warn "スキーマを照合できませんでした (${CMP})" \
             "openAPISchema が chart/values.schema.json と一致することを手動で確認してください"
        ;;
    esac
  fi

  # --- アイコン ---------------------------------------------------------------
  # ダッシュボードは base64 に収めた SVG を期待し、画像を取りに外へ行かない。ここでのエラーは
  # 静かである: マニフェストは適用されるが、カタログのアイコンの場所は空になる。だから文字列を
  # デコードし、中身が本当に SVG かを確認する。
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "アイコンが base64 からデコードされ、SVG であることが分かります"
        evidence "アイコンの先頭" "$ICON_HEAD"
        ;;
      "")
        fail "アイコンが base64 からデコードできません" \
             "文字列を作り直してください: base64 -i icon.svg | tr -d '\\n' (Linux では: base64 -w0 icon.svg)"
        ;;
      *)
        fail "アイコンはデコードできますが、SVG ではありません" \
             "ダッシュボードはまさに SVG を期待します; ラスター画像はゴミとして表示されます"
        ;;
    esac
  fi
fi

# --- 権限: ここでの拒否は想定内 --------------------------------------------
# これは参加者のチェックではなく、プラットフォームの仕組みの確認である。だから
# 答えが `no` なら成功であり、`yes` は喜ぶのではなく驚くべき理由である。
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "確認済み: あなたに ApplicationDefinition の適用は許可されていません (can-i -> no)"
      evidence "ApplicationDefinition の権限" \
        "kubectl auth can-i create applicationdefinitions -> no
オブジェクトは cluster-scoped で、すべてのテナントのカタログを変更するため、適用するのはプラットフォーム管理者である。"
      ;;
    yes)
      warn "あなたには ApplicationDefinition を適用する権限があります (can-i -> yes)" \
           "つまり、テナントアカウントではなく管理者アカウントで作業しています; ラボはテナントアカウントを想定しています"
      ;;
    *)
      warn "クラスターに権限を問い合わせできませんでした" \
           "ラボの合格には支障ありません: チェックはローカルで、ここではクラスターは不要です"
      ;;
  esac
else
  warn "クラスターに問い合わせていません (KUBECONFIG が未設定か応答しません)" \
       "チェックはローカルで、ここではクラスターは不要です。権限の拒否を確認するには: export KUBECONFIG=~/.kube/config"
fi

finish
