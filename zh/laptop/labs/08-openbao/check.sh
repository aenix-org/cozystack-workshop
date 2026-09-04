#!/usr/bin/env bash
# 实验 8 检查：密码已从清单中移出，存入 OpenBao 并按规则存活。
#
# 我们检查的不是「对象已创建」，而是实质：存储库已解封，密钥可凭令牌读取，
# 版本多于一个（说明确实发生过轮换），审计已启用，而已应用的应用清单中没有
# 明文密码。
#
# 没有任何密钥进入报告。值不会在任何地方被打印。
#
# 脚本会启动带 curl 的一次性 Pod，因此运行约需一分钟。

# LAB_NAME 和 LAB_TITLE 进入报告的表头。下面引入通用的检查库：
# 从中取得 ok / warn / fail / evidence / finish 以及在集群内运行一次性 Pod 的
# 函数。need_kubeconfig 和 need_tenant 会在访问权限或租户编号未设置时提前
# 停止脚本：否则会一次性全部失败，从报告里无法看出原因。
LAB_NAME="08-openbao"
LAB_TITLE="实验 8 · 密钥不在清单里"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- 看哪里 ---------------------------------------------------------
# 参与者把 COZY_TENANT 设为 `workshop07`，但 namespace 叫作
# `tenant-workshop07`。两种写法我们都接受：这里很容易搞错，而
# 错误消息又会含糊不清（「服务无响应」）。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 我们找什么、在哪里找。BAO_APP 是租户中 OpenBao 应用的名字，它是存储库
# 内部地址的一部分：如果你给应用起了别的名字，就以 BAO_APP=名字 ./check.sh
# 的方式运行检查。SECRET_PATH 是存储库内部的路径，实验把数据库密码放在那里。
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "存储库地址" "$BAO_URL"

# 从标准输入的 JSON 中按键链取出一个值。
# 如果路径不存在或不是 JSON 则返回 1，这样调用方就能区分
# 「没有这个键」和「值为空」。
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for k in sys.argv[1:]:
    try:
        d = d[int(k)] if isinstance(d, list) else d[k]
    except Exception:
        sys.exit(1)
print("" if d is None else d)
' "$@" 2>/dev/null
}


# 向 OpenBao 发起请求。令牌通过来自临时 Secret 的环境变量传入，
# 而不是作为参数中的头部：Pod 的参数任何有 `get pods` 权限的人都能看到，它们
# 存在 etcd 里并进入审计日志。这里是存储库的 root 令牌——正是这整个实验
# 所要防范的泄露。
#
# 定义放在第一次调用之前：当它曾放在 else 分支里时，最开头的那个检查会调用
# 一个不存在的函数，导致实验永远无法通过。
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. 存储库有响应 -------------------------------------------------
# 第一个请求就同时回答两个问题：应用起来了没有，租户编号对不对。我们询问封印
# 状态——这是 OpenBao 唯一无需令牌就提供的端点。此后若响应为空，就意味着
# 「没有连接」，所有对内容的检查都失去意义。
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao 在地址 ${BAO_URL} 上无响应" \
       "检查 COZY_TENANT 中的租户编号和应用名（默认 'secrets'；否则用 BAO_APP=名字 ./check.sh）；在仪表盘中应用必须处于就绪状态"
else
  ok "OpenBao 在租户的内部地址上有响应"
fi

# --- 2. 已初始化 --------------------------------------------------------
# 初始化是一次性操作，存储库在此过程中为自己创建主密钥和第一个令牌。
# 在完成之前，里面什么都没有：既没有密钥，也没有存放它们的地方。
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "存储库已初始化"
elif [ -n "$SEAL" ]; then
  fail "存储库未初始化" \
       "执行：kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 并保存输出"
fi

# --- 3. 已解封 --------------------------------------------------------
# 封印状态的存储库是 Pod 重启后的正常状态：数据在磁盘上，但在输入解封密钥之前
# 没有任何东西能读取它。因此要求检查行为，而不是对象是否存在：「应用已就绪」和
# 「密钥可被提供」是两个不同的论断，后者并不能从前者推出。
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "存储库已解封并正在处理请求"
  evidence "存储库状态" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "存储库处于封印状态——对任何请求都以 503 拒绝回应" \
       "执行：kubectl exec bao-workbench -- bao operator unseal <你的解封密钥>"
  evidence "存储库状态" "$SEAL"
fi

# --- 4. 密钥就位且可读 -----------------------------------------
# 接下来需要令牌。没有它就无从检查，但也不能默默跳过：
# 读者必须看到缺了什么。
if [ -z "$SEAL" ]; then
  # 没有连接——检查内容毫无意义。我们保持沉默，以免让报告里出现四个
  # 有着同一个上面已指出的原因的失败。
  warn "未检查存储库内容：与 OpenBao 没有连接" \
       "先解决连接问题，然后再次运行脚本"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "未设置 BAO_TOKEN 变量，因此未检查存储库内容" \
       "export BAO_TOKEN='存储库首次解封时打印出的 root 令牌' 并再次运行脚本"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "密钥 secret/${SECRET_PATH} 可凭令牌读取，password 字段不为空"
    # 我们把版本号放进报告，而不是值。
    evidence "密钥" "路径：secret/${SECRET_PATH}
password 字段：有（值已隐藏）
当前版本：${DATA_VERSION:-未知}"
  else
    fail "路径 secret/${SECRET_PATH} 下没有 password 字段" \
         "把它放进去：kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ；如果引擎尚未启用——bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. 确实发生过轮换 --------------------------------------------------
  # 密钥只有唯一一个版本，意味着它被放进去后就被遗忘了。轮换正是设立存储库的
  # 目的：在一个地方改密码，而不是在清单里到处找它。我们数的不是承诺，而是
  # 版本：版本的计数由存储库自己维护。
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "密钥被改过：共 ${CUR_VER} 个版本，说明轮换不只是嘴上说说"
    evidence "密钥版本历史" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "密钥只有一个版本——没有做过轮换" \
         "更改密码：kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<新值> 并重启应用"
  fi

  # --- 6. 策略是收窄的，而不是「什么都行」 ---------------------------------
  # 策略恰恰是对「拿到令牌的人能做什么」这个问题的回答。因此我们看的不是它是否
  # 存在，而是它的内容：它是授予某个具体路径而不是整个存储库，且是否只读。
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "策略 passes-read 存在"
    evidence "策略 passes-read" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "策略授予的是某个具体路径，而不是整个存储库"
    else
      warn "策略存在，但在其中看不到路径 secret/data/${SECRET_PATH}" \
           "检查策略中是否写了 data 前缀：secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "策略允许的不只是读取" \
           "应用只需要 read；多余的权限应当移除"
    fi
  else
    fail "未找到策略 passes-read" \
         "创建它：kubectl exec -i bao-workbench -- bao policy write passes-read - < 你的策略文件（策略讲解见 README）"
  fi

  # --- 7. 审计已启用 ----------------------------------------------------
  # 没有审计日志，就无从回答「谁在何时读了这个密钥」——而这是事故之后要问的
  # 第一个问题。我们统计已挂接的审计设备：至少要有一个。
  AUD="$(bao_get "/v1/sys/audit")"
  AUD_COUNT="$(printf '%s' "$AUD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
data = d.get("data", d)
print(len([k for k in data if isinstance(data.get(k), dict)]))
' 2>/dev/null)"
  case "$AUD_COUNT" in
    ''|*[!0-9]*) AUD_COUNT=0 ;;
  esac
  if [ "$AUD_COUNT" -ge 1 ]; then
    ok "审计日志已启用（设备数：${AUD_COUNT}）"
    evidence "审计设备" "$AUD"
  else
    fail "审计日志未启用——将无从回答谁读了密钥" \
         "启用它：kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. 实验集群里的应用 ---------------------------------
# 到目前为止我们检查的是管理集群上的存储库。接下来是你的 lab 集群，
# 应用本身就住在那里。这里重要的不是 Deployment 已被创建这个事实，而是有没有
# 就绪的副本：一个没能取到密码的 init 容器不会让 Pod 起来，而这正是要与
# 「一切正常」区分开的状态。
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "实验集群里没有应用 ${APP_DEPLOY}" \
       "应用它：kubectl apply -f secrets-demo.yaml（别忘了替换成你自己的租户编号）"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "应用 ${APP_DEPLOY} 已启动（就绪副本数：${READY}）"
  else
    fail "应用 ${APP_DEPLOY} 存在，但没有一个副本就绪" \
         "查看 kubectl describe deploy/${APP_DEPLOY} 和 kubectl logs deploy/${APP_DEPLOY} -c fetch-secret——通常是 init 容器无法访问存储库或被令牌拒绝"
  fi

  # --- 9. 清单中没有明文密码 -------------------------
  # 我们看的是已应用的对象，而不是磁盘上的文件：被应用的可能是任何东西。
  LEAKS="$(kubectl get deploy "$APP_DEPLOY" -o json 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
suspicious = re.compile(r"(?i)pass|secret|token|key|cred")
spec = d.get("spec", {}).get("template", {}).get("spec", {})
found = []
for c in list(spec.get("initContainers", [])) + list(spec.get("containers", [])):
    for e in c.get("env", []):
        if "value" in e and suspicious.search(e.get("name", "")):
            found.append("%s / env %s 是用值设定的，而不是引用" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "应用清单中没有用值设定密码的变量"
  else
    fail "应用清单里仍残留有明文的敏感值" \
         "去掉它们：值应当来自存储库，而清单里只应保留一个引用。见 secrets-demo.yaml"
    evidence "在清单中找到的内容" "$LEAKS"
  fi

  # --- 10. 应用确实收到了密钥 ------------------------
  # 最后的证据我们从日志里取，而不是从对象描述里。清单可以无懈可击，而密码却
  # 从未到达 Pod。我们同时看两件事：init 容器报告它去了存储库，且应用打印出
  # 一个指纹——说明它确实在用收到的密码工作。
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "init 容器从存储库取到了密钥"
    evidence "init 容器日志" "$INIT_LOG"
  else
    fail "看不出 init 容器从存储库取过密钥" \
         "检查 kubectl logs deploy/${APP_DEPLOY} -c fetch-secret；如果没有这个容器——那是应用了旧清单"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "应用在用收到的密码工作（日志里写的是指纹，而不是值）"
    evidence "应用日志" "$APP_LOG"
  else
    fail "应用日志里没有密码的指纹" \
         "检查 kubectl logs deploy/${APP_DEPLOY} -c app——容器可能没有启动"
  fi
fi

# --- 11. 幼稚的密钥已移除 ----------------------------------------------
# 只有实验确实做过时才算「已移除」：在干净的集群上这个密钥从来不存在，
# 而报告却会因一次从未发生过的清理去表扬参与者。
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "集群里仍残留着幼稚阶段的密钥 passes-db" \
       "它不再需要，且含有旧密码：kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "幼稚的密钥 passes-db 已移除"
fi

finish
