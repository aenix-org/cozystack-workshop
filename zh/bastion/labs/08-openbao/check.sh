#!/usr/bin/env bash
# 实验 8 的检查：密码已从清单中移出到 OpenBao，并按规则存放。
#
# 我们检查的不是"对象已创建"，而是本质：存储库已解封，密钥可以
# 通过令牌读取，版本不止一个（说明确实进行了轮换），审计
# 已启用，且已应用的应用清单中没有明文密码。
#
# 任何密钥都不会进入报告。任何地方都不打印其值。
#
# 脚本会启动带 curl 的一次性 Pod，因此运行约需一分钟。

# LAB_NAME 和 LAB_TITLE 进入报告的标题栏。下面引入通用的检查
# 库：从中获取 ok / warn / fail / evidence / finish 以及在集群内
# 启动一次性 Pod 的函数。need_kubeconfig 和 need_tenant
# 会提前停止脚本，如果没有设置访问权限或租户编号：否则
# 一切会同时失败，从报告中无法看出原因。
LAB_NAME="08-openbao"
LAB_TITLE="实验 8 · 密钥不在清单中"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- 看哪里 ---------------------------------------------------------
# 参与者将 COZY_TENANT 设置为 `workshop07`，但命名空间叫做
# `tenant-workshop07`。两种写法都接受：这里很容易出错，而
# 错误信息会含糊不清（"服务无响应"）。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 查找什么以及在哪里查找。BAO_APP 是租户中 OpenBao 应用的名称，它是
# 存储库内部地址的一部分：如果给应用起了别的名字，请以
# BAO_APP=名称 ./check.sh 的方式运行检查。SECRET_PATH 是存储库内的路径，
# 实验在该路径下放置数据库密码。
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "存储库地址" "$BAO_URL"

# 从标准输入的 JSON 中按键链取出一个值。
# 如果路径不存在或不是 JSON 则返回 1，这样调用方可以区分
# "没有该键"和"空值"。
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


# 向 OpenBao 发起请求。我们通过来自临时 Secret 的环境变量传递令牌，
# 而不是作为参数中的请求头：任何拥有 `get pods` 权限的人都能看到 Pod 的参数，它们存在
# etcd 中并进入 audit log。这里是存储库的 root 令牌——正是
# 整个实验所针对的那种泄漏。
#
# 定义位于第一次调用之前：当它位于 else 分支内部时，最
# 开头的检查会调用一个不存在的函数，实验永远无法通过。
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. 存储库有响应 -------------------------------------------------
# 第一个请求就同时回答两个问题：应用是否已启动，以及租户
# 编号是否正确。我们询问封印状态——这是 OpenBao 唯一
# 无需令牌即可提供的端点。后续的空响应意味着"无连接"，所有对内容的
# 检查都失去意义。
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao 在地址 ${BAO_URL} 上无响应" \
       "请检查 COZY_TENANT 中的租户编号和应用名称（默认为 'secrets'；否则 BAO_APP=名称 ./check.sh）；在仪表板中应用应处于就绪状态"
else
  ok "OpenBao 在租户的内部地址上有响应"
fi

# --- 2. 已初始化 --------------------------------------------------------
# 初始化是一次性操作，存储库在此过程中为自己创建主密钥
# 和第一个令牌。在完成之前，里面什么都没有：既没有密钥，也没有存放它们的位置。
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "存储库已初始化"
elif [ -n "$SEAL" ]; then
  fail "存储库未初始化" \
       "执行：kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 并保存输出"
fi

# --- 3. 已解封 -----------------------------------------------------------
# 封印的存储库是 Pod 重启后的正常状态：数据在磁盘上
# 存着，但在输入 unseal 密钥之前无法读取。因此要求
# 检查行为，而不是对象是否存在："应用就绪"和"密钥可被提供"——
# 这是两个不同的论断，后者并不由前者推出。
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "存储库已解封并正在处理请求"
  evidence "存储库状态" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "存储库已封印——对任何请求都以 503 拒绝作答" \
       "执行：kubectl exec bao-workbench -- bao operator unseal <你的-unseal-密钥>"
  evidence "存储库状态" "$SEAL"
fi

# --- 4. 密钥就位且可读 --------------------------------------
# 接下来需要令牌。没有它就无从检查，但也不能默默跳过：
# 读者应该看到缺少了什么。
if [ -z "$SEAL" ]; then
  # 没有连接——检查内容毫无意义。我们保持沉默，以免用四个
  # 同出一因（上面已说明）的失败塞满报告。
  warn "未检查存储库内容：与 OpenBao 无连接" \
       "先解决连接问题，然后再次运行脚本"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "未设置 BAO_TOKEN 变量，因此未检查存储库内容" \
       "export BAO_TOKEN='首次解封存储库时打印的 root 令牌' 然后再次运行脚本"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "密钥 secret/${SECRET_PATH} 可通过令牌读取，password 字段非空"
    # 报告中放入版本号，而不是值。
    evidence "密钥" "路径：secret/${SECRET_PATH}
password 字段：有（值已隐藏）
当前版本：${DATA_VERSION:-未知}"
  else
    fail "路径 secret/${SECRET_PATH} 下没有 password 字段" \
         "放置它：kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ；如果引擎尚未启用——bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. 确实进行了轮换 --------------------------------------
  # 密钥只有唯一一个版本意味着放进去后就被遗忘了。轮换
  # 正是设立存储库的目的：在一个地方更换密码，而不是在
  # 各个清单中四处寻找。我们统计的不是承诺，而是版本：其计数由存储库自己维护。
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "密钥被更改过：${CUR_VER} 个版本，说明轮换不只是嘴上说说"
    evidence "密钥版本历史" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "密钥只有一个版本——没有进行轮换" \
         "更换密码：kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<新的> 并重启应用"
  fi

  # --- 6. 策略是收窄的，而非"什么都行" ---------------------------------
  # 策略正是对"拿到令牌的人能做什么"这一问题的回答。因此
  # 我们看的不是它是否存在，而是其内容：它是否针对具体
  # 路径而非整个存储库授予，以及是否仅为只读。
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "策略 passes-read 存在"
    evidence "策略 passes-read" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "策略是针对具体路径授予的，而不是整个存储库"
    else
      warn "策略存在，但其中看不到路径 secret/data/${SECRET_PATH}" \
           "请检查策略中使用了 data 前缀：secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "策略允许的不仅仅是读取" \
           "应用只需 read；多余的权限应当移除"
    fi
  else
    fail "未找到策略 passes-read" \
         "创建它：kubectl exec -i bao-workbench -- bao policy write passes-read - < 你的策略文件（策略讲解见 README）"
  fi

  # --- 7. 审计已启用 ----------------------------------------------------
  # 没有审计日志，就无法回答"谁在何时读取了这个密钥"——而这是
  # 事件发生后被问到的第一个问题。我们统计已挂接的日志
  # 设备：至少应有一个。
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
    fail "审计日志未启用——将无从回答谁读取了密钥" \
         "启用它：kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. 实验集群中的应用 ---------------------------------
# 到目前为止我们在管理集群上检查存储库。接下来是你的 lab 集群，
# 应用本身就住在那里。这里重要的不是 Deployment 已创建这一事实，而是是否有
# 就绪的副本：未能取到密码的 init 容器不会让 Pod 启动，
# 而正是这个状态需要与"一切正常"区分开。
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "实验集群中没有应用 ${APP_DEPLOY}" \
       "应用它：kubectl apply -f secrets-demo.yaml（别忘了替换成你自己的租户编号）"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "应用 ${APP_DEPLOY} 已运行（就绪副本数：${READY}）"
  else
    fail "应用 ${APP_DEPLOY} 存在，但没有任何副本就绪" \
         "查看 kubectl describe deploy/${APP_DEPLOY} 和 kubectl logs deploy/${APP_DEPLOY} -c fetch-secret——通常是 init 容器无法连到存储库或令牌被拒绝"
  fi

  # --- 9. 清单中没有明文密码 -------------------------
  # 我们看的是已应用的对象，而不是磁盘上的文件：可能应用的是任何东西。
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
            found.append("%s / env %s 是以值设置的，而不是引用" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "应用清单中没有以值设置密码的变量"
  else
    fail "应用清单中仍有明文的敏感值" \
         "移除它们：值应来自存储库，而清单中只放引用。参见 secrets-demo.yaml"
    evidence "在清单中发现了什么" "$LEAKS"
  fi

  # --- 10. 应用确实收到了密钥 ------------------------
  # 最后的证据来自日志，而不是对象的描述。清单可以
  # 完美无缺，而密码却始终没有到达 Pod。我们同时看两件事：
  # init 容器报告它去过存储库，且应用打印出指纹——
  # 说明它确实在用取到的密码工作。
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "init 容器已从存储库取回密钥"
    evidence "init 容器日志" "$INIT_LOG"
  else
    fail "看不到 init 容器从存储库取回密钥的迹象" \
         "检查 kubectl logs deploy/${APP_DEPLOY} -c fetch-secret；如果没有该容器——应用的是旧清单"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "应用在用取到的密码工作（日志中写的是指纹，而不是值）"
    evidence "应用日志" "$APP_LOG"
  else
    fail "应用日志中没有密码指纹" \
         "检查 kubectl logs deploy/${APP_DEPLOY} -c app——容器可能未能启动"
  fi
fi

# --- 11. 已移除幼稚的密钥 ----------------------------------------------
# 只有在实验确实做过的情况下才算作"已删除"：在干净的集群上密钥
# 从来就不存在，而报告会因一次从未发生的清理去表扬参与者。
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "集群中仍留有幼稚阶段的 passes-db 密钥" \
       "它不再需要且含有旧密码：kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "幼稚的 passes-db 密钥已删除"
fi

finish
