#!/usr/bin/env bash
# ラボ13のチェック: チャートとアプリ定義が管理者への引き渡しに耐える状態か確認する。
#
# このチェックは意図的にローカル完結。テナントは ApplicationDefinition を適用できない
# （オブジェクトが cluster-scoped）ため、クラスタ内で探しても意味がない。
# オブジェクトが存在しないのは参加者の落ち度ではない。ここでは参加者が責任を負う範囲
# ——チャートがビルドでき、スキーマが機能し、定義がパースでき、チャートと一致している——を確認する。
#
# ラボのフォルダから実行:
#   cd labs/13-catalog && ./check.sh
# クラスタは必須ではない: KUBECONFIG がなければ 2 つのチェックはエラーではなく警告として
# スキップされる。

LAB_NAME="13-catalog"
LAB_TITLE="ラボ13 · Cozystack カタログに自作アプリを載せる"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- ツール -----------------------------------------------------------------
# helm がなければチェックするものが何もないので、スクリプトはここで即座に止まり、
# この先で同じ失敗を大量に吐き続けることはしない。
if ! command -v helm >/dev/null 2>&1; then
  fail "このマシンに helm が入っていません" \
       "インストールしてください: brew install helm (macOS) または https://helm.sh/docs/intro/install/ — これがないとラボは検証できません"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm があります (${HELM_VER})"
evidence "helm のバージョン" "$HELM_VER"

# --- チャートがある ---------------------------------------------------------
# 「チャートが壊れている」と「スクリプトを間違ったフォルダから実行した」を区別する。
# 後者のミスの方が前者より多く、そのメッセージは分けておくべきだ。
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "${CHART} にチャートが見つかりません" \
       "スクリプトはラボのフォルダから実行してください: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- リンタ ----------------------------------------------------------------
# helm lint はチャートをテキストとして読む: テンプレートのタイポ、Chart.yaml の
# 欠けたフィールド、存在しない値への参照を見つける。ここではクラスタまでは行かない。
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "チャートは helm lint を通ります"
  evidence "helm lint" "$LINT_OUT"
else
  fail "チャートが helm lint を通りません" \
       "下の出力を読んで指摘されたファイルを直してください: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- レンダリング ----------------------------------------------------------------
# 空の出力やコメントだけの出力はリンタをすり抜けるので、レンダリング結果に Deployment が
# 含まれているか確認し、実際に何が出てきたかを列挙する。
# ここで大事なのは「コマンドが動いた」ことではなく「本物のオブジェクトが生成された」ことだ。
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "チャートがレンダリングでき、オブジェクトが生成されます: ${KINDS}"
  evidence "チャートがレンダリングするもの" "$KINDS"
else
  fail "helm template が Deployment を 1 つも生成しませんでした" \
       "レンダリングエラーを確認してください: helm template main chart"
  evidence "helm template の出力" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- チャートが本物のクラスタに受理される ----------------------------------
# ラボ全体で唯一、マニフェストをテキストではなく本物のクラスタのスキーマに照らして
# 検証するチェック。
#
# `helm lint` と `helm template` はテンプレートは確認するが、Kubernetes のスキーマは確認しない:
# フィールドが誤った位置にあるマニフェストは両者をすり抜けるが、クラスタはそれを拒否する。
# 身をもって学んだ——volumes の中に誤って入れられた securityContext が両者を通り抜け、
# サーバ上でだけ崩れた。このチェックはチャートが適用される場所でこそ必要だ。
#
# なぜ lint と template では代替できないのか:
#   helm lint      はチャートの構造を見る: ファイルが揃っているか、テンプレートがパースできるか;
#   helm template  は値を差し込んでテキストを出力する——だがそのフィールドが何であり、
#                  そのオブジェクトにそもそも存在しうるかは、知らないし知りようもない;
#   apply --dry-run=server はマニフェストを apiserver に送り、apiserver がそれを型スキーマと
#                  admission 制御に通し、受理するかどうかを答える。その際に何も作成しない。
#                  ゆえに `unknown field` やポリシーによる拒否が出る——
#                  まさに顧客の環境でチャートがつまずくところだ。
# --dry-run=client フラグではこのチェックはできない: マニフェストを自分のマシン上でパースするだけだ。
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # 権限による拒否とスキーマによる拒否は別物であり、混同してはならない。テナントアクセス
  # (~/.kube/workshop) では Deployment と ConfigMap の権限がそもそもないので、ここには
  # Forbidden が飛んでくる——そしてそれはチャートの品質について何も語らない。本質的な
  # チェックは、あなたが完全な所有者である `lab` クラスタへのアクセスでしか行えない。
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "サーバ側のチャートチェックはスキップ: 現在のアクセスでは実行できません" \
         "自分のクラスタへのアクセスで実行してください: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "クラスタがレンダリングされたチャートを拒否しました" \
         "確認: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "サーバの拒否" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "クラスタがレンダリングされたチャートを受理しました — フィールドとその位置は正しい"
  fi
else
  warn "クラスタに対するチャートチェックはスキップ: アクセスがありません" \
       "KUBECONFIG を設定して helm template を kubectl apply --dry-run=server に通してください"
fi

# --- パラメータが本当にマニフェストまで届く -------------------------
# チャートがビルドでき、レンダリングもできるのに、パラメータがどこにも差し込まれない
# ——たとえば値がテンプレートに数値として直書きされている——ことがある。そこで各パラメータを
# 実際に試す: 明らかに珍しい値を与え、それが完成したマニフェストに現れるか探す。
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "replicas パラメータがマニフェストまで届きます (--set replicas=5 で replicas: 5 になる)"
else
  fail "replicas パラメータがマニフェストまで届きません" \
       "templates/deployment.yaml に replicas: {{ .Values.replicas }} と書いてください"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "external パラメータが Service の type を LoadBalancer に切り替えます"
else
  warn "external パラメータが Service の type を切り替えません" \
       "チャートの不具合ではないが、Cozystack カタログの慣習: アプリの external フィールドはまさに外部アクセスを意味する"
fi

# --- スキーマが本当に守る ------------------------------------------
# 何も拒否しないスキーマは役に立たない。ちゃんと拒否するか確認する。
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "値のスキーマが明らかに不正な値を拒否しません (replicas=abc が通った)" \
       "values.yaml の隣に values.schema.json があり、その中で replicas が integer として宣言されているか確認してください"
else
  ok "値のスキーマが誤った型を拒否します (replicas=abc は通らない)"
fi

# --- ApplicationDefinition: 必須フィールド ------------------------------
# 参加者は定義を適用できないので、apiserver の拒否も目にしない。そこで必須フィールドを
# ここで数え上げる: どれか一つでも欠けると、管理者は自分の側で拒否を受け、その始末は
# ファイルの作者に回ってくる。
if [ ! -f "$APPDEF" ]; then
  fail "見つかりません: ${APPDEF}" \
       "このファイルはチャートの隣に置くべきものです。ラボのリポジトリから取ってください"
else
  MISSING=""
  # YAML をパースせず、キーを 1 行ずつ探す: PyYAML はどのマシンにもあるわけではなく、
  # 1 ファイルの確認のために依存を持ち込む価値はない。
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
    fail "ApplicationDefinition にフィールドが足りません:${MISSING}" \
         "README の解説と突き合わせてください — どれか一つでも欠けると管理者は適用時に拒否を受けます"
  fi

  # --- 定義内のスキーマがパースでき、チャートのスキーマと一致する ---------
  # これは同じものの 2 つの別コピーであり、両者に何のリンクもない。
  # ズレると、ダッシュボードのフォームはチャートが期待しないフィールドを表示する。
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "ApplicationDefinition の openAPISchema が空です" \
         "そこに chart/values.schema.json の内容を 1 行で入れてください"
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
    print("DIFF 定義にのみ: %s | チャートにのみ: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "定義内のスキーマがパースでき、チャートのスキーマと一致します (${CMP#SAME })"
        evidence "アプリのパラメータ" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "定義内のスキーマがチャートのスキーマとズレています: ${CMP#DIFF }" \
             "一致させてください: openAPISchema の内容は chart/values.schema.json を 1 行にしたものです"
        ;;
      BADJSON*)
        fail "openAPISchema が JSON としてパースできません: ${CMP#BADJSON }" \
             "スキーマは 'openAPISchema: |-' の下に正しい JSON を 1 行で書く必要があります"
        ;;
      *)
        warn "スキーマを照合できませんでした (${CMP})" \
             "openAPISchema が chart/values.schema.json と一致するか手で確認してください"
        ;;
    esac
  fi

  # --- アイコン ---------------------------------------------------------------
  # ダッシュボードは base64 に詰めた SVG を期待し、画像を取りに外へは行かない。ここでの
  # エラーは静かだ: マニフェストは適用されるが、カタログではアイコンの場所が空になる。そこで
  # 文字列をデコードし、中身が本当に SVG か確認する。
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "アイコンが base64 からデコードでき、SVG であることが分かりました"
        evidence "アイコンの先頭" "$ICON_HEAD"
        ;;
      "")
        fail "アイコンが base64 からデコードできません" \
             "文字列を作り直してください: base64 -i icon.svg | tr -d '\\n' (Linux では: base64 -w0 icon.svg)"
        ;;
      *)
        fail "アイコンはデコードできますが、SVG ではありません" \
             "ダッシュボードはまさに SVG を期待します。ラスタ画像はゴミとして表示されます"
        ;;
    esac
  fi
fi

# --- 権限: ここでの拒否は想定内 --------------------------------------------
# これは参加者のチェックではなく、プラットフォームの作りの確認だ。だから
# `no` という答えが成功であり、`yes` は喜ぶことではなく驚くべきことだ。
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "確認済み: あなたに ApplicationDefinition の適用は許可されていません (can-i -> no)"
      evidence "ApplicationDefinition に対する権限" \
        "kubectl auth can-i create applicationdefinitions -> no
オブジェクトは cluster-scoped で全テナントのカタログを変えるため、適用するのはプラットフォーム管理者です。"
      ;;
    yes)
      warn "あなたには ApplicationDefinition を適用する権限があります (can-i -> yes)" \
           "つまりテナントではなく管理者アカウントで作業しています。ラボはテナントアカウントを想定しています"
      ;;
    *)
      warn "クラスタに権限を問い合わせられませんでした" \
           "ラボの合格には支障ありません: チェックはローカルで、ここではクラスタは不要です"
      ;;
  esac
else
  warn "クラスタに問い合わせていません (KUBECONFIG 未設定か応答なし)" \
       "チェックはローカルで、ここではクラスタは不要です。権限の拒否を見るには: export KUBECONFIG=~/.kube/workshop"
fi

finish
