#!/usr/bin/env bash
# 实验 12 检查：迁移后的虚拟机通过平台的 ingress 和域名对外发布，
# 与容器化应用完全一样。
#
# 我们检查的不是「对象已创建」，而是它是否真正在工作：
#   1) 租户的域名返回 HTTP 200，并且这是通讯录页面，
#   2) 虚拟机本身正在运行（Ready），
#   3) 发布该机器的 Ingress 已就位。
# 第一项是最主要的：它就是通讯录从外部可见的证明。
#
# 在笔记本上运行，从本实验的目录执行。需要租户访问权限和租户编号：
#     export KUBECONFIG=~/.kube/workshop
#     export COZY_TENANT=workshopXX
#     cd labs/12-vm && ./check.sh
# 域名检查即使没有租户访问权限也能工作——它只需要 curl。没有租户访问权限时
# 脚本不会失败：它会跳过租户侧的检查并如实说明。
#
# 脚本不做任何修改——它只读取并发送 HTTP 请求。请在清理之前运行：
# 一旦机器被删除，就没有什么可检查的了。

# 这两个变量由 lib.sh 读取——它们会进入报告头部以及脚本放在自己旁边的
# 文件名 report-<实验>-<日期>.md。
LAB_NAME="12-vm"
LAB_TITLE="实验 12 · 与容器并肩的虚拟机"
# 通用检查库：ok / fail / warn / evidence / finish 都来自这里。
# 路径是相对于脚本自身所在位置解析的，因此从任何目录运行效果都一样。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 租户编号是必需的：它构成 namespace 名称以及发布通讯录的域名。
# 没有它就没有什么可检查的。
need_tenant

# 我们要检查的名称。VM 是机器「订单」的名称，即 VMInstance 对象的名称；
# `kubectl get vminstance` 查询的就是它。实际运行的实例名称不同：
# 平台用 `vm-instance` chart 部署该订单，chart 名称与 release 名称拼接在一起，
# 于是得到 vm-instance-spravochnik。
VM=spravochnik
NS="tenant-${COZY_TENANT}"
# 主持人预先通过 Ingress 发布通讯录所用的域名。就是你在浏览器里打开的那个地址。
HOST="spravochnik.${COZY_TENANT}.workshop.aenix.io"
URL="http://${HOST}"

# 租户访问不是必需的：域名用普通的 curl 检查。如果设置了 KUBECONFIG
# 且租户有响应——我们会额外检查机器状态和 Ingress。
TENANT_OK=0
if [ -n "${KUBECONFIG:-}" ] && kubectl -n "$NS" get vminstance >/dev/null 2>&1; then
  TENANT_OK=1
fi

# --- 主要内容：通讯录通过域名从外部可见 ---------------------------
# 我们分别取响应码和响应体：响应码区分「ingress 后面还没人」（503）、
# 「指向了错误的地方」（404）和「根本没有域名」（000），
# 而响应体确认应答的正是通讯录，而不是某个随机的占位页。
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)"
BODY="$(curl -s --max-time 10 "$URL" 2>/dev/null)"

case "$CODE" in
  200)
    case "$BODY" in
      *"员工通讯录"*)
        ok "通讯录已发布：${URL} 返回 200 并提供通讯录页面"
        evidence "域名响应" "请求：${URL}
响应码：${CODE}
$(printf '%s' "$BODY" | head -3)"
        ;;
      *)
        fail "${URL} 返回 200，但这不是通讯录页面" \
             "域名后面应答的是别的东西；请检查机器内部 8080 端口上监听的正是通讯录"
        ;;
    esac
    ;;
  503)
    fail "域名 ${URL} 返回 503——Ingress 后面还没有人可以应答" \
         "机器仍在启动，或 8080 上的通讯录服务尚未起来；请等待 vminstance 变为 Ready 并查看机器控制台"
    ;;
  000)
    fail "域名 ${URL} 完全没有响应" \
         "请检查网络；带此主机名的 Ingress 由主持人创建——如果根本没有域名，请询问他"
    ;;
  *)
    fail "域名 ${URL} 返回 ${CODE}，而不是 200" \
         "404 表示 Ingress 指向了错误的服务；5xx 表示后端尚未准备好应答"
    ;;
esac

# --- 租户侧：机器本身及其发布 --------------------------
if [ "$TENANT_OK" -eq 0 ]; then
  warn "已跳过租户侧检查：无法通过 KUBECONFIG 访问租户" \
       "请提供租户访问权限：export KUBECONFIG=~/.kube/workshop"
else
  # 我们查询的不是「对象是否存在」，而是 Ready 条件：机器订单一秒就能创建，
  # 而客户机启动需要三到五分钟，这段时间机器一直存在，
  # 但通讯录还不应答。
  if ! kubectl -n "$NS" get vminstance "$VM" >/dev/null 2>&1; then
    fail "租户 ${NS} 中没有虚拟机 ${VM}" \
         "在仪表盘中创建 VM Disk 和 VM Instance，或应用 staff-directory-vm.yaml"
  else
    VM_READY="$(kubectl -n "$NS" get vminstance "$VM" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [ "$VM_READY" = "True" ]; then
      ok "虚拟机 ${VM} 正在运行"
    elif [ -n "$VM_READY" ]; then
      fail "虚拟机 ${VM} 存在，但尚未就绪（Ready=${VM_READY}）" \
           "请查看仪表盘中的机器卡片；首次启动需要 3-5 分钟"
    else
      warn "虚拟机 ${VM} 存在，但无法读取其状态" \
           "请在仪表盘中亲眼查看：它应当处于开机状态"
    fi
    evidence "租户的虚拟机" "$(kubectl -n "$NS" get vminstance 2>/dev/null)"
  fi

  # Ingress 由主持人创建，而不是参与者。如果域名已经返回 200——它就已就位；
  # 我们单独检查，以便在 503/404 时立即看清究竟有没有发布。
  if kubectl -n "$NS" get ingress spravochnik >/dev/null 2>&1; then
    ok "Ingress spravochnik 已就位——通讯录已在租户中发布"
    evidence "租户的 Ingress" "$(kubectl -n "$NS" get ingress spravochnik 2>/dev/null)"
  else
    warn "在租户 ${NS} 中未找到 Ingress spravochnik" \
         "它由主持人创建；如果域名已经返回 200——无需担心，否则请联系主持人"
  fi
fi

finish
