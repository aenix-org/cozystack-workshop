#!/usr/bin/env bash
# ラボ11のチェック: Android ビルドが最後まで走り、APK がバケットまで届いたか。
#
# 「Job が作成された」ではなく、互いに等価ではない3つの主張を検証する:
#   1) Job が正常に完了したこと、
#   2) その中で実際に APK がビルドされたこと（BUILD SUCCESSFUL）、
#   3) ファイルが実際にオブジェクトストレージへ届いたこと（APK-UPLOADED マーカー）。
# 誰かがスクリプトを書き換えれば、Job は正常に完了しつつ何もビルドしないこともある。
#
# VM 上で、このラボのフォルダから、学習用クラスタ `lab` へのアクセスを使って実行する
# （管理クラスタ上のテナントではない — ビルドはクラスタ内で走る）:
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# スクリプトはクラスタを一切変更しない — 読み取りと HTTP リクエストの送信だけを行う。
# 片付けの前に実行すること: Job を削除するとそのログも消え、ログがなければ
# 上記3つの主張のうち2つを確認する術が残らない。

# この2つの変数は lib.sh が拾う — レポートのヘッダーと、スクリプトが自身の隣に置く
# report-<ラボ>-<日付>.md というファイル名に入る。
LAB_NAME="11-android"
LAB_TITLE="ラボ11 · クラスタ内でのモバイルアプリのビルド"
# 共通チェックライブラリ: ok / fail / warn / evidence / finish、クラスタ内リクエスト、
# レポートの書き出しはここから来る。パスはスクリプト自身の場所を基準に解決されるので、
# どのディレクトリから実行しても同じように動く。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG が未設定なら即座に停止する。これがないと kubectl は VM 自身の上に
# クラスタを探し、見つからず、すべてのチェックを同じエラーで連続して落とし、
# そこから本当の原因が見えなくなる。
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# シークレットのキーの値。base64 -d はどこでも同じではない（BSD 対 GNU）ので、
# python でデコードする — チェックライブラリがすでにそれを必要としている。
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- バケットアクセス用のシークレット -------------------------------------------
# シークレットの存在ではなく、その中の4つのフィールドがすべて埋まっていることを確認する。
# シークレットは4つの --from-literal を連ねて手作業で作られ、最もよくある不具合は
# 空または欠けた値だ: オブジェクトは正常に作られるのに、ビルドは最後のステップで、
# ビルドがすでに通ったあとに落ちる。今知る方が安上がりだ。
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "シークレット ${SECRET} は所定の場所にあり、4つのキーすべてが埋まっている"
    # キーの値はレポートに入らない — フィールド名だけが入る。
    evidence "シークレット ${SECRET} のフィールド" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <非表示>
secretKey: <非表示>"
  else
    fail "シークレット ${SECRET} に未入力のフィールドがある:${MISSING}" \
         "README のコマンドでシークレットを作り直す。値はダッシュボードで取得する: Bucket -> builds -> Secrets"
  fi
else
  fail "クラスタにシークレット ${SECRET} が存在しない" \
       "シークレットを作成する: kubectl create secret generic ${SECRET} --from-literal=endpoint=...（4つのフィールド）"
fi

# --- ストレージにクラスタ内から到達できるか --------------------------------
# 「Job が5番目のステップで落ちた」の最もよくある原因は、キーではなく、
# クラスタからストレージに到達できないことだ。これをビルドとは別に確認する。
# リクエストは VM からではなくポッドから出す: VM には独自のネットワークと経路があり、
# その成功応答はビルドがそこへ届くかについて何も語らないからだ。
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # 意図的に -k なし: ビルドは証明書検証つきでストレージへ行くので、チェックは
  # Job が落ちるのと同じ場所で落ちねばならず、期限切れ証明書でグリーンを出してはならない。
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "ストレージ ${EP} はクラスタ内から応答する（HTTP ${CODE}）"
      evidence "ストレージの応答" "GET https://${EP}/ -> HTTP ${CODE}
コード 403 と 404 はここでは正常: S3 ルートへの匿名リクエストは拒否されるべきものだ。"
      ;;
    5*)
      warn "ストレージ ${EP} がエラー HTTP ${CODE} を返す" \
           "ビルドは通るかもしれないが APK のアップロードは通らない可能性がある。講師に伝えること"
      ;;
    *)
      fail "ストレージ ${EP} がクラスタ内から応答しない" \
           "シークレットの endpoint フィールドを確認する: https:// なし、末尾のスラッシュなしでなければならない"
      ;;
  esac
else
  warn "ストレージの到達性は確認しない" \
       "まず endpoint フィールドを持つシークレット ${SECRET} が必要だ"
fi

# --- Job そのもの ---------------------------------------------------------------
# Job の存在ではなく .status.succeeded を見る: オブジェクトは即座に必ず正常に作られ、
# タスクの成功はポッドがコード 0 で終了したことを意味する。
# ポッドの状態は別に調べる。なぜなら「まだ実行中」と「Pending で止まっている」は
# 人間にとって別の知らせだからだ: 前者は待てということ、後者は待っても無駄で
# ノードを大きくする必要があるということ。
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "クラスタに Job ${JOB} が存在しない" \
       "ビルドを開始する: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} は正常に完了した"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
完了: ${DURATION:-不明}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "ビルドのポッドが Pending で止まっている — 起動していないし、自分では起動しない" \
         "原因を確認する: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; Insufficient memory の場合はノードを u1.large まで大きくする — やり方は README に書いてある"
    evidence "ビルドポッドのイベント" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} はエラーで完了した（失敗した試行回数: ${FAILED}）" \
         "ログの最後の行を見る: kubectl logs job/${JOB} --tail=40"
    evidence "落ちたビルドのログの末尾" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} はまだ完了していない（ポッドの状態: ${POD_PHASE:-不明}）" \
         "最初のビルドは回線次第で数分から15分ほどかかる。追いかける: kubectl logs -f job/${JOB}"
  fi

  # --- 中で実際に何が起きたか ----------------------------------------
  # 正常な Job それ自体は、リターンコードがゼロだったこと以外は何も証明しない。
  # そこでログを開き、2つの別々の証拠を探す: BUILD SUCCESSFUL —
  # コンパイルが最後まで走ったこと、そして APK-UPLOADED というマーカー行、これは
  # ファイルをバケットへコピーしたあとにだけスクリプトが出力する。後者は前者より強い: APK は
  # ビルドされても、まさに消えようとしているポッドの中に留まっていることがある。
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "ビルドのログが参照できない" \
         "ビルドポッドが削除されたか、まだ作成されていない。ログがなければ APK が実際にビルドされたことを確認できない"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK は実際にビルドされた（${GRADLE_LINE}）"
    else
      fail "ログに BUILD SUCCESSFUL の行がない — コンパイルが最後まで走らなかった" \
           "FAILURE を含む最初の行を探す: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK はバケットへ届いた: ${UPLOADED}"
      evidence "ビルド後のバケットの中身" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK в бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK はビルドされたが、バケットへは届かなかった" \
           "ログの末尾を見る: kubectl logs job/${JOB} --tail=20; 犯人はたいてい bucketName だ — 'builds' ではなく、ダッシュボードにある長い名前が必要"
    fi
  fi
fi

# --- ノードにこのビルドのための空きが足りるか --------------------------------
# 判決ではなく説明だ: Job が収まらなかったなら、原因はほぼ必ずここにある。
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "最大のノードはメモリを ${BIGGEST_H} 提供している — ビルドには足りる"
      else
        warn "最大のノードがメモリを ${BIGGEST_H} しか提供していない" \
             "ビルドは requests だけで 4Gi を要求する。Job が Pending で止まるなら、ノードタイプを u1.large まで大きくする — やり方は README に書いてある"
      fi
      ;;
    *)
      warn "ノードの利用可能メモリが1ギガバイト未満（${BIGGEST_H}）" \
           "Android ビルドはそこに収まらない。ノードタイプを大きくする — やり方は README に書いてある"
      ;;
  esac
  evidence "ノードのリソース" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
