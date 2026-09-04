#!/usr/bin/env bash
# 实验 11 的检查：Android 构建跑到了最后，且 APK 送达了存储桶。
#
# 我们检查的不是「Job 已创建」，而是三条彼此不同、且互不等价的断言：
#   1) Job 成功结束，
#   2) 其内部确实构建出了 APK（BUILD SUCCESSFUL），
#   3) 文件确实上传到了对象存储（APK-UPLOADED 标记）。
# Job 可能成功结束却什么都没构建 —— 如果有人改动了脚本。
#
# 在笔记本上运行，从本实验的目录，使用对训练集群 `lab` 的访问权限
# （不是管理集群上的租户 —— 构建是在集群里进行的）：
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# 脚本不会改动集群里的任何东西 —— 只做读取并发送 HTTP 请求。
# 请在清理之前运行它：删除 Job 时会一并删掉它的日志，而没有日志
# 就无从确认上面三条断言中的两条。

# 这两个变量由 lib.sh 读取 —— 它们会进入报告标题，以及脚本放在自己旁边的
# 文件名 report-<实验>-<日期>.md。
LAB_NAME="11-android"
LAB_TITLE="实验 11 · 在集群中构建移动应用"
# 通用检查库：ok / fail / warn / evidence / finish、集群内部请求以及报告写入
# 都来自这里。路径是相对于脚本自身所在位置解析的，因此从任何目录运行效果都一样。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 如果未设置 KUBECONFIG，立即停止。没有它，kubectl 会在笔记本本机上寻找集群，
# 找不到，然后接连让每一项检查都以同一个错误失败，从中看不出真正的原因。
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# 取某个 secret 键的值。base64 -d 各处并不一致（BSD 对 GNU），
# 因此用 python 来解码 —— 检查库本来就需要它。
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- 拥有存储桶访问权限的 secret -------------------------------------------
# 我们检查的不是 secret 是否存在，而是其中四个字段是否都已填写。
# secret 是手工创建的，用四个连续的 --from-literal，最常见的麻烦就是
# 某个值为空或漏填：这时对象仍会创建成功，而构建会在最后一步失败，
# 此时构建其实已经跑完。现在就发现要便宜得多。
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "secret ${SECRET} 已就位，四个键都已填写"
    # 键的值不进入报告 —— 只写字段名。
    evidence "secret ${SECRET} 的字段" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <已隐藏>
secretKey: <已隐藏>"
  else
    fail "secret ${SECRET} 中以下字段未填写：${MISSING}" \
         "用 README 里的命令重新创建 secret，值在仪表盘中获取：Bucket -> builds -> Secrets"
  fi
else
  fail "集群里没有 secret ${SECRET}" \
       "创建 secret：kubectl create secret generic ${SECRET} --from-literal=endpoint=...（四个字段）"
fi

# --- 从集群内部能否访问到存储 --------------------------------
# 「Job 在第五步失败」最常见的原因不是密钥，而是从集群里够不到存储。
# 我们把这一点与构建分开检查。
# 请求是从 pod 发出的，而不是从笔记本：笔记本有自己的网络和路由，
# 它成功的响应完全说明不了构建能否够到那里。
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # 故意不加 -k：构建访问存储时会校验证书，而检查必须在 Job 同样会失败的地方失败，
  # 而不是在过期证书上给出绿色通过。
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "存储 ${EP} 从集群内部有响应（HTTP ${CODE}）"
      evidence "存储的响应" "GET https://${EP}/ -> HTTP ${CODE}
403 和 404 在这里是正常的：对 S3 根路径的匿名请求本就应被拒绝。"
      ;;
    5*)
      warn "存储 ${EP} 返回错误 HTTP ${CODE}" \
           "构建也许能通过，但 APK 上传不行；请告诉讲师"
      ;;
    *)
      fail "存储 ${EP} 从集群内部没有响应" \
           "检查 secret 里的 endpoint 字段：它必须不带 https:// 且结尾不带斜杠"
      ;;
  esac
else
  warn "不检查存储可用性" \
       "先需要带 endpoint 字段的 secret ${SECRET}"
fi

# --- Job 本身 ---------------------------------------------------------------
# 我们看的是 .status.succeeded，而不是 Job 是否存在这件事：对象会瞬间创建
# 且总是成功，而任务的成功意味着 pod 以 0 码结束。
# pod 的状态单独考察，因为对人来说「还在跑」和「卡在 Pending」是不同的消息：
# 前者意味着等一等，后者意味着等下去也没用，需要扩大节点。
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "集群里没有 Job ${JOB}" \
       "启动构建：kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} 成功结束"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
完成时间：${DURATION:-未知}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "构建 pod 卡在 Pending —— 它没有启动，也不会自行启动" \
         "查看原因：kubectl describe pod -l job-name=${JOB} | grep -A5 Events；遇到 Insufficient memory 时把节点扩大到 u1.large —— 如何操作写在 README 里"
    evidence "构建 pod 的事件" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} 以错误结束（失败尝试次数：${FAILED}）" \
         "查看日志最后几行：kubectl logs job/${JOB} --tail=40"
    evidence "失败构建日志的尾部" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} 还没结束（pod 状态：${POD_PHASE:-未知}）" \
         "首次构建视网络情况需要几分钟到一刻钟不等；观察：kubectl logs -f job/${JOB}"
  fi

  # --- 内部到底发生了什么 ----------------------------------------
  # 成功的 Job 本身除了零返回码之外什么都证明不了。
  # 因此我们打开日志，在其中寻找两条不同的证据：BUILD SUCCESSFUL ——
  # 说明编译跑到了最后，以及标记行 APK-UPLOADED，脚本只有在把文件复制到存储桶之后
  # 才会打印它。第二条比第一条更有力：APK 可能已构建出来，却留在了即将消失的 pod 内部。
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "构建日志不可用" \
         "构建 pod 已被删除或尚未创建；没有日志就无法确认 APK 确实已构建"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK 确实已构建（${GRADLE_LINE}）"
    else
      fail "日志里没有 BUILD SUCCESSFUL 这一行 —— 编译没跑到最后" \
           "查找第一条带 FAILURE 的行：kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK 已送达存储桶：${UPLOADED}"
      evidence "构建后存储桶的内容" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK в бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK 已构建，但没有送达存储桶" \
           "查看日志尾部：kubectl logs job/${JOB} --tail=20；多数情况是 bucketName 的锅 —— 它需要仪表盘里的长名字，而不是 'builds'"
    fi
  fi
fi

# --- 节点是否有足够空间承载这样的构建 --------------------------------
# 不是判决，而是解释：如果 Job 放不下，原因几乎总在这里。
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "最大的节点提供 ${BIGGEST_H} 内存 —— 够构建用"
      else
        warn "最大的节点仅提供 ${BIGGEST_H} 内存" \
             "光 requests 构建就要 4Gi；如果 Job 卡在 Pending，把节点类型扩大到 u1.large —— 如何操作写在 README 里"
      fi
      ;;
    *)
      warn "各节点可用内存不足一个 GB（${BIGGEST_H}）" \
           "Android 构建放不进去，请扩大节点类型 —— 如何操作写在 README 里"
      ;;
  esac
  evidence "节点资源" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
