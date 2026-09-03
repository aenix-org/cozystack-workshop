# 检查脚本

每个实验目录里都有一个 `check.sh`。它验证实验是否真正完成——不是「文件已应用」，而是**在实质上确实能工作**。

你随时可以自己运行它。结果是终端里的一份报告，以及一个可以附到任何地方的产物文件：社区聊天、认证申请、你自己的笔记。

## 如何运行

```bash
cd labs/03-scale
./check.sh
```

你现在就在 bastion（Linux）上——`bash`、`kubectl` 以及你需要的一切都已就绪，无需安装任何东西。访问实验集群 `lab` 的凭据——就是你在实验 0 里创建的那个 `lab.kubeconfig`——脚本通过 `KUBECONFIG` 变量找到它：

```bash
export KUBECONFIG=~/lab.kubeconfig
```

> 如果你不是在 bastion 上、而是从自己的 Windows 机器上做实验——如何安装 WSL、以及从哪里获取 `lab.kubeconfig`，都写在笔记本套件里：
> [`../../laptop/check/README.md`](../../laptop/check/README.md)。

脚本会自己通过 `KUBECONFIG` 变量判断该去哪里找。如果没有设置这个变量，它会告诉你并停止。

对于需要访问管理集群上某个租户的实验，你还需要 `COZY_TENANT` 变量——你的租户名称，例如 `workshop07`：

```bash
export COZY_TENANT=workshop07
./check.sh
```

## 你会得到什么

在终端里——每项检查一行：

```
[  OK  ] application deployed and responding
[  OK  ] Pod name is injected into the page
[ FAIL ] autoscaling is not configured
         no HorizontalPodAutoscaler found for deployment/rickroll
         hint: apply hpa.yaml from this folder
```

⚠️ **报告会写入实验目录，并带有日期和时间。** 如果仓库是共用的，或者你已经跑过好几次检查，那里就会堆积起好几个文件——看名字里的时间，别把别人的或之前的一次运行当成自己的。

在它旁边会出现一个 `report-<lab>-<date>.md` 文件——同样的结果，用 Markdown 呈现，连同收集到的证据：版本、命令输出、对象名称。这就是那个产物。

## 对脚本作者的要求

**检查实质，而不是应用这个动作本身。** 反例：「存在一个 Deployment 对象」。正例：「应用通过 HTTP 响应，且响应里包含 Pod 的名称」。

**每次失败都要说明该做什么。** 一行没有提示的 `FAIL` 就是次品。读者运行脚本，恰恰是因为他们卡住了。

**脚本既不修复也不创建。** 它只读取。唯一的例外是用于检查网络可达性的临时 Pod，它会在用完后自行清理。

**在 macOS 和 Linux 上都能工作。** 不用 GNU 特有的 `sed -i`、`readlink -f`、`date -d`。要在两个系统上都测试。

**不在第一个错误处就停下。** 它会跑完每一项检查，展示完整的全貌。不要用 `set -e`。

**不打印密码和令牌。** 如果某个值是机密，就写 `<hidden>`。

**幂等。** 连续运行十次不会改变集群的状态。

## 共享库

`check/lib.sh`——共享函数，在每个脚本开头被引入：

- `ok "text"` / `fail "text" "hint"` / `warn "text"`——打印一条结果
- `need_kubeconfig`——检查 `KUBECONFIG` 已设置且集群有响应
- `need_tenant`——检查 `COZY_TENANT` 已设置
- `evidence "heading" "value"`——向产物里添加一条证据
- `finish`——汇总、写入报告、返回退出码

退出码：`0`——全部通过，`1`——存在失败。这样脚本就可以用在自动化流程里。
