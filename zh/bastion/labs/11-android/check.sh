#!/usr/bin/env bash
# 实验 11 的检查：Android 构建是否跑到了最后，APK 是否进了 bucket。
#
# 我们验证的不是「Job 已创建」，而是三个互不相同的论断，它们彼此并不等价：
#   1) Job 成功结束，
#   2) 在其内部确实构建出了 APK（BUILD SUCCESSFUL），
#   3) 文件确实进了对象存储（APK-UPLOADED 标记）。
# Job 可以成功结束却什么都没构建出来——如果有人改动了脚本。
#
# 在虚拟机上运行，从本实验目录，使用对训练集群 `lab` 的访问
#（不是管理集群上的租户——构建是在集群里进行的）：
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# 脚本不会改动集群中的任何东西——它只读取并发送 HTTP 请求。
# 请在清理之前运行它：删除 Job 会连同它的日志一起删除，而没有日志就没有任何东西
# 能确认上面三个论断中的两个。

# 这两个变量由 lib.sh 读取——它们会进入报告的标题，并进入脚本放在自己旁边的
# 文件名 report-<实验>-<日期>.md。
LAB_NAME="11-android"
LAB_TITLE="实验 11 · 在集群中构建移动应用"
# 通用检查库：ok / fail / warn / evidence / finish、集群内部请求以及报告的写入
# 都来自这里。路径相对于脚本自身所在的位置解析，因此从任何目录运行效果都一样。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 如果 KUBECONFIG 未设置，立即停止。没有它 kubectl 会在虚拟机本身上寻找集群，
# 找不到，然后用同一个错误连续让所有检查失败，从这个错误里看不出真正的原因。
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# 取 secret 某个键的值。base64 -d 各处并不一致（BSD 对 GNU），
# 所以用 python 解码——检查库本来就需要它。
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- 带 bucket 访问权限的 secret -------------------------------------------
# 我们检查的不是 secret 是否存在，而是其中四个字段是否都已填好。
# secret 是手工创建的，连着四个 --from-literal，最常见的麻烦就是
# 某个值为空或漏填：这样对象能成功创建，但构建会在最后一步失败，
# 而那时构建已经跑完了。现在就发现更省事。
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "secret ${SECRET} 就位，四个键都已填好"
    # 键的值不会进入报告——只有字段名进入。
    evidence "secret ${SECRET} 的字段" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <已隐藏>
secretKey: <已隐藏>"
  else
    fail "secret ${SECRET} 有未填写的字段:${MISSING}" \
         "用 README 里的命令重新创建 secret，值在仪表盘中获取: Bucket -> builds -> Secrets"
  fi
else
  fail "集群中没有 secret ${SECRET}" \
       "创建 secret: kubectl create secret generic ${SECRET} --from-literal=endpoint=...（四个字段）"
fi

# --- 从集群内部能否访问到存储 --------------------------------
# 「Job 在第五步挂了」最常见的原因不是密钥，而是从集群里够不着存储。
# 我们把这一点和构建分开来检查。请求是从 Pod 发出的，而不是从虚拟机：
# 虚拟机有自己的网络和自己的路由，它的成功响应并不能说明构建能否到达那里。
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # 故意不加 -k：构建是带证书校验访问存储的，检查必须在 Job 会失败的同一处失败，
  # 而不是在过期证书上给出绿灯。
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "存储 ${EP} 从集群内部有响应（HTTP ${CODE}）"
      evidence "存储的响应" "GET https://${EP}/ -> HTTP ${CODE}
这里出现 403 和 404 是正常的：对 S3 根路径的匿名请求本就应该被拒绝。"
      ;;
    5*)
      warn "存储 ${EP} 以错误 HTTP ${CODE} 响应" \
           "构建可能通过，但 APK 上传不会；请告知讲师"
      ;;
    *)
      fail "存储 ${EP} 从集群内部没有响应" \
           "检查 secret 中的 endpoint 字段：它必须不带 https:// 且结尾不带斜杠"
      ;;
  esac
else
  warn "不检查存储可用性" \
       "先需要带 endpoint 字段的 secret ${SECRET}"
fi

# --- Job 本身 ---------------------------------------------------------------
# 我们看的是 .status.succeeded，而不是 Job 是否存在这个事实：对象会瞬间创建，
# 且总是成功，而任务成功意味着 Pod 以 0 码结束。
# Pod 的状态单独分析，因为「还在跑」和「卡在 Pending」对人来说是不同的消息：
# 前者意味着再等等，后者意味着等下去没用，需要把节点扩大。
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "集群中没有 Job ${JOB}" \
       "启动构建: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} 成功结束"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
已完成: ${DURATION:-未知}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "构建 Pod 卡在 Pending——它没有启动，也不会自己启动" \
         "查看原因: kubectl describe pod -l job-name=${JOB} | grep -A5 Events；遇到 Insufficient memory 时把节点扩大到 u1.large——具体做法见 README"
    evidence "构建 Pod 的事件" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} 以错误结束（失败尝试次数: ${FAILED}）" \
         "查看日志的最后几行: kubectl logs job/${JOB} --tail=40"
    evidence "失败构建的日志尾部" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} 还没有结束（Pod 状态: ${POD_PHASE:-未知}）" \
         "首次构建耗时从几分钟到一刻钟不等，取决于网络；跟踪查看: kubectl logs -f job/${JOB}"
  fi

  # --- 内部到底发生了什么 ----------------------------------------
  # 一个成功的 Job 本身除了零返回码之外什么也证明不了。
  # 所以我们打开日志，在里面找两处不同的证据：BUILD SUCCESSFUL——
  # 说明编译跑到了最后，以及标记行 APK-UPLOADED，脚本只在把文件复制进 bucket 之后
  # 才会打印它。第二个比第一个更有力：APK 可能被构建出来，却留在一个即将消失的 Pod 里。
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "构建日志不可用" \
         "构建 Pod 已被删除或尚未创建；没有日志就无法确认 APK 确实构建出来了"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK 确实构建出来了（${GRADLE_LINE}）"
    else
      fail "日志里没有 BUILD SUCCESSFUL 这行——编译没有跑到最后" \
           "找第一行带 FAILURE 的: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK 进了 bucket: ${UPLOADED}"
      evidence "构建后 bucket 的内容" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 正在将 APK 上传到 Bucket/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK 构建出来了，但没进 bucket" \
           "查看日志尾部: kubectl logs job/${JOB} --tail=20；最常见的元凶是 bucketName——它需要仪表盘里那个长名字，而不是 'builds'"
    fi
  fi
fi

# --- 节点是否有足够空间容纳这样的构建 --------------------------------
# 这不是判决，而是解释：如果 Job 没放下，原因几乎总是在这里。
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "最大的节点提供 ${BIGGEST_H} 内存——够构建用"
      else
        warn "最大的节点只提供 ${BIGGEST_H} 内存" \
             "光 requests 构建就要 4Gi；如果 Job 卡在 Pending，把节点类型扩大到 u1.large——怎么做见 README"
      fi
      ;;
    *)
      warn "节点上可用内存不足一个 GB（${BIGGEST_H}）" \
           "Android 构建放不进去，扩大节点类型——怎么做见 README"
      ;;
  esac
  evidence "节点资源" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
