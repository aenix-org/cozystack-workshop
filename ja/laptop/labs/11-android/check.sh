#!/usr/bin/env bash
# ラボ11のチェック: Android ビルドが最後まで完走し、APK がバケットに到達したこと。
#
# 「Job が作成された」ではなく、互いに等しくない3つの異なる主張を確認する:
#   1) Job が正常に完了したこと、
#   2) その内部で実際に APK がビルドされたこと（BUILD SUCCESSFUL）、
#   3) ファイルが実際にオブジェクトストレージへ届いたこと（APK-UPLOADED マーカー）。
# 誰かがスクリプトを書き換えれば、Job は正常に完了しつつ何もビルドしないこともある。
#
# ノートPC上で、このラボのフォルダから、学習用クラスタ `lab` へのアクセスを使って実行する
# （管理クラスタ上のテナントではない — ビルドはクラスタ内で走る）:
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# このスクリプトはクラスタ内を一切変更しない — 読み取りと HTTP リクエストの送信のみ。
# 後片付けの前に実行すること: Job を削除するとそのログも一緒に消え、ログがなければ
# 上記3つのうち2つを確認する手立てが残らない。

# この2つの変数は lib.sh が拾う — レポートのヘッダと、スクリプトが自分の隣に置く
# ファイル名 report-<ラボ>-<日付>.md に入る。
LAB_NAME="11-android"
LAB_TITLE="ラボ11 · クラスタ内でのモバイルアプリのビルド"
# 共通チェックライブラリ: ここから ok / fail / warn / evidence / finish、
# クラスタ内からのリクエスト、レポート書き込みが来る。パスはスクリプト自身の場所から
# 解決されるので、どのディレクトリから実行しても同じように動く。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG が未設定なら即座に止まる。これがないと kubectl はノートPC自身の中に
# クラスタを探し、見つからず、同じエラーで全チェックを次々に落とし、
# そこからは本当の原因が見えない。
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# シークレットのキーの値。base64 -d はどこでも同じとは限らない（BSD 対 GNU）ので、
# python でデコードする — チェックライブラリがすでに python を必要としている。
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- バケットへのアクセスを持つシークレット -------------------------------------------
# シークレットの存在ではなく、その中の4つのフィールドすべてが埋まっていることを確認する。
# シークレットは手作業で、4つの --from-literal を連ねて作る。最もよくある不具合は
# 空または欠けた値だ: オブジェクトは正常に作成されるのに、ビルドが最終ステップ、
# つまりビルドがすでに通り過ぎたあとで落ちる。今のうちに知るほうが安上がりだ。
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "シークレット ${SECRET} は所定の場所にあり、4つのキーすべてが埋まっている"
    # キーの値はレポートに入らない — フィールド名だけ。
    evidence "シークレット ${SECRET} のフィールド" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <非表示>
secretKey: <非表示>"
  else
    fail "シークレット ${SECRET} で次のフィールドが埋まっていない:${MISSING}" \
         "README のコマンドでシークレットを作り直してください。値はダッシュボードで取得します: Bucket -> builds -> Secrets"
  fi
else
  fail "クラスタにシークレット ${SECRET} がない" \
       "シークレットを作成してください: kubectl create secret generic ${SECRET} --from-literal=endpoint=...（4つのフィールド）"
fi

# --- ストレージにクラスタ内から到達できるか --------------------------------
# 「Job が5番目のステップで落ちた」の最もよくある原因はキーではなく、クラスタから
# ストレージに到達できないことだ。これをビルドとは別に確認する。
# リクエストはノートPCからではなくポッドから出る: ノートPCには独自のネットワークと経路があり、
# その成功応答は、ビルドがそこへ届くかどうかについて何も語らないからだ。
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # あえて -k を付けない: ビルドは証明書検証ありでストレージにアクセスするので、チェックは
  # Job が落ちるのと同じ場所で落ちるべきであり、期限切れ証明書で緑を出してはならない。
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "ストレージ ${EP} はクラスタ内から応答する（HTTP ${CODE}）"
      evidence "ストレージの応答" "GET https://${EP}/ -> HTTP ${CODE}
コード 403 と 404 はここでは正常です: S3 ルートへの匿名リクエストは拒否されるべきだからです。"
      ;;
    5*)
      warn "ストレージ ${EP} はエラー HTTP ${CODE} で応答する" \
           "ビルドは通っても APK のアップロードは通らないかもしれません。ファシリテーターに伝えてください"
      ;;
    *)
      fail "ストレージ ${EP} はクラスタ内から応答しない" \
           "シークレットの endpoint フィールドを確認してください: https:// なし、末尾スラッシュなしでなければなりません"
      ;;
  esac
else
  warn "ストレージの可用性は確認しない" \
       "まずは endpoint フィールドを持つシークレット ${SECRET} が必要です"
fi

# --- Job そのもの ---------------------------------------------------------------
# Job が存在するという事実ではなく .status.succeeded を見る: オブジェクトは瞬時に、そして
# 常に正常に作成されるが、タスクの成功はポッドがコード0で終了したことを意味する。
# ポッドの状態は別に調べる。「まだ実行中」と「Pending で止まっている」は人間にとって
# 別の報せだからだ: 前者は待てを意味し、後者は待っても無駄で、
# ノードを増強する必要があることを意味する。
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "クラスタに Job ${JOB} がない" \
       "ビルドを起動してください: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} が正常に完了した"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
完了: ${DURATION:-不明}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "ビルドのポッドが Pending で止まっている — 起動しておらず、自力では起動しない" \
         "原因を見てください: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; Insufficient memory の場合はノードを u1.large に増強してください — やり方は README に書いてあります"
    evidence "ビルドポッドのイベント" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} がエラーで終了した（失敗した試行回数: ${FAILED}）" \
         "ログの最後の行を見てください: kubectl logs job/${JOB} --tail=40"
    evidence "失敗したビルドログの末尾" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} はまだ完了していない（ポッドの状態: ${POD_PHASE:-不明}）" \
         "最初のビルドは回線によって数分から15分ほどかかります。追ってください: kubectl logs -f job/${JOB}"
  fi

  # --- 内部で正確に何が起きたか ----------------------------------------
  # Job の成功はそれ自体では、ゼロの戻り値以外に何も証明しない。
  # そこでログを開き、その中に2つの異なる証拠を探す: BUILD SUCCESSFUL —
  # コンパイルが最後まで走ったこと、そしてスクリプトがファイルをバケットへコピーした
  # あとにのみ表示するマーカー行 APK-UPLOADED。後者は前者より強い: APK はビルドされても、
  # まさに消えようとしているポッドの中に置き去りにされることがあるからだ。
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "ビルドログが利用できない" \
         "ビルドのポッドが削除されたか、まだ作成されていません。ログがなければ APK が実際にビルドされたことを確認できません"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK は実際にビルドされた（${GRADLE_LINE}）"
    else
      fail "ログに BUILD SUCCESSFUL の行がない — コンパイルが最後まで走らなかった" \
           "FAILURE を含む最初の行を探してください: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK がバケットに到達した: ${UPLOADED}"
      evidence "ビルド後のバケットの内容" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK в бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK はビルドされたが、バケットに到達しなかった" \
           "ログの末尾を見てください: kubectl logs job/${JOB} --tail=20; 多くの場合 bucketName が原因です — 'builds' ではなく、ダッシュボードの長い名前が必要です"
    fi
  fi
fi

# --- このようなビルドにノードの空きが足りるか --------------------------------
# 判決ではなく説明: Job が入りきらなかったなら、原因はほぼ確実にここにある。
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "最大のノードは ${BIGGEST_H} のメモリを提供する — ビルドには十分"
      else
        warn "最大のノードは ${BIGGEST_H} のメモリしか提供しない" \
             "ビルドは requests だけで 4Gi を要求します。Job が Pending で止まる場合はノードタイプを u1.large に増強してください — やり方は README に書いてあります"
      fi
      ;;
    *)
      warn "ノードの利用可能メモリが1ギガバイト未満（${BIGGEST_H}）" \
           "Android ビルドはそこに収まりません。ノードタイプを増強してください — やり方は README に書いてあります"
      ;;
  esac
  evidence "ノードのリソース" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
