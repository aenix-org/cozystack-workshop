# Glossary — canonical terminology

This table fixes how key terms are handled so every language reads consistently
and no term drifts. Two rules override everything else:

1. **Product, project and CLI names are never translated or transliterated** —
   in any language they stay exactly as written here.
2. **Kubernetes object and command names stay in English** even in Chinese and
   Spanish prose (this is what real localized Kubernetes documentation does).
   Translate the *idea* around them, not the identifier.

## Never translated — keep verbatim in every language

Cozystack · Kubernetes · KubeVirt · Talos · Flux · GitOps · Helm ·
vSphere · vCenter · ESXi · DRS · Harbor · Redis · PostgreSQL · ClickHouse ·
MongoDB · Kafka · OpenBao · MinIO · Keycloak · Grafana · Prometheus

`kubectl` · `virtctl` · `kubelogin` · `kubeconfig` ·
`namespace` · `Pod` · `Deployment` · `Service` · `Secret` · `ConfigMap` ·
`Ingress` · `LoadBalancer` · `PersistentVolumeClaim` / `PVC` ·
`HorizontalPodAutoscaler` / `HPA` · `VMInstance` · `VMDisk` · `Bucket` ·
`apply` (as the `kubectl apply` verb) · `reconcile` (as the Flux verb, when it
names the mechanism)

Also verbatim: all file and directory names, all command output, everything
inside code fences, the tenant placeholder `workshopXX`, the paths
`~/.kube/config` and `~/lab.kubeconfig`.

## Translated concepts — use these targets

| Concept (ru) | English | 中文 (zh) | Español (es) |
|---|---|---|---|
| кластер | cluster | 集群 | clúster |
| control plane | control plane | 控制平面 | plano de control |
| узел (node) | node | 节点 | nodo |
| тенант | tenant | 租户 | tenant |
| манифест | manifest | 清单 (manifest) | manifiesto |
| применить (kubectl apply) | apply | 应用 | aplicar |
| реконсиляция / сводит к желаемому | reconcile / reconciliation | 调谐 (reconcile) | reconciliación |
| самолечение | self-healing | 自愈 | autoreparación |
| автомасштабирование | autoscaling | 自动扩缩容 | autoescalado |
| выкатка / раскатка | rollout | 滚动发布 | despliegue (rollout) |
| образ | image | 镜像 | imagen |
| диск | disk | 磁盘 | disco |
| сеть | network | 网络 | red |
| хранилище | storage | 存储 | almacenamiento |
| виртуалка / виртуальная машина | virtual machine (VM) | 虚拟机 | máquina virtual (VM) |
| контейнер | container | 容器 | contenedor |
| управляющий кластер | management cluster | 管理集群 | clúster de gestión |
| учебный кластер `lab` | lab cluster `lab` | 实验集群 `lab` | clúster de laboratorio `lab` |
| виртуалка-bastion / джамп-хост | the bastion (shared VM) | bastion（跳板机） | el bastion (VM compartida) |
| дашборд | dashboard | 控制台 (dashboard) | panel (dashboard) |
| квота | quota | 配额 | cuota |
| секрет (объект) | Secret | Secret | Secret |

When a term is not in this table, prefer the wording that a native engineer
would actually use in that language's Kubernetes documentation — never a raw
transliteration of the English word.

## Resolved consistency decisions (one rendering, everywhere)

These were pinned after review to stop drift. Use exactly these:

| Concept (ru) | Canonical English | Note |
|---|---|---|
| ведущий (the person leading the workshop) | **the instructor** | never "the host" — "host" means a machine here |
| стенд | **testbed** | never the calque "stand" |
| зоопарк (the metaphor for a sprawl of tools) | **menagerie** | one word, everywhere the metaphor recurs |
| виртуалка / джамп-хост (the shared VM you SSH into) | **the bastion** | never "VM" — reserve "VM"/"virtual machine" for actual VMs and VMInstances |
| Pod (the Kubernetes object) | **Pod** (capitalized) | even in running prose |

## Reader-facing placeholders (translate — they are instructions, not code)

Descriptive fill-in placeholders are meant to be replaced by the reader, so they
are localized in every language (in prose AND in the shipped file), even though
they sit inside code:

| ru placeholder | English |
|---|---|
| `ЗдесьВашПароль` | `YourPasswordHere` |
| `ваш-пароль-passapp` | `your-passapp-password` |
| `ВАШ-ЛОГИН` | `YOUR-LOGIN` |
| `ЗАМЕНИТЕ-МЕНЯ` | `REPLACE-ME` |
| `пароль` (as a placeholder value) | `password` |
| `хост` (as a placeholder value) | `host` |
| `<адрес-виртуалки>` | `<bastion-address>` |
| `<имя>` | `<name>` |
| `имя.yaml` | `name.yaml` |
| `/Users/имя`, `/home/имя` | `/Users/name`, `/home/name` |
| `<скрыто>` | `<hidden>` |
| credential labels `логин:` / `пароль:` / `хост:` / `база:` | `login:` / `password:` / `host:` / `database:` |

**Keep verbatim** (functional tokens the scripts/manifests actually depend on):
`workshopXX`, `ВСТАВЬТЕ_PRESIGNED_URL`, `ВСТАВЬТЕ_...` fields in `convert.sh`,
and every other identifier that appears unchanged in the shipped files.

## Chinese (zh) — resolved canonical renderings

Pinned after review to stop drift. Use exactly these Chinese head-terms everywhere
(gloss `（English）` at first mention is fine; the head-term must be identical after):

| Concept | 中文 (use this) | not |
|---|---|---|
| testbed | **测试环境** | 不用 raw "testbed" / 测试台 |
| menagerie (the metaphor) | **动物园** | 不用 大杂烩 / 乱七八糟的东西 — one image everywhere, incl. index & headings |
| the instructor (ведущий) | **讲师** | 不用 raw "instructor" |
| workshop (the event) | **工作坊** | 不用 raw "workshop" |
| catalog (platform catalog) | **目录** | 不用 raw "catalog" |
| presigned link/URL | **预签名链接 / 预签名 URL** | 不用 raw "presigned" |
| manifest | **清单** | 不用 raw "manifest" |
| lab cluster `lab` | **实验集群 `lab`** | keep the `lab` backticks; not bare "lab 集群" |
| ESXi host / host (the machine) | **主机** | 不用 raw "host" in prose |
| reservation (vSphere) | **资源预留（reservation）** first, **预留** after | 不用 raw "reservation" |
| hypervisor | **虚拟机监控程序（hypervisor）** | 不用 bare "hypervisor" |
| home directory | **主目录** | 不用 "home 目录" |

Punctuation in Chinese prose: use the full-width colon `：` (not `:`) and corner
brackets `「」` for quoted/emphasized phrases — consistently across all files.
Colons inside code fences, inline code, URLs, ports and ratios stay half-width.

## Spanish (es) — resolved canonical renderings

Pinned after review. Use exactly these; no raw English where a Spanish term exists:

| Concept | Español (use this) | not |
|---|---|---|
| testbed / стенд | **entorno de pruebas** | not raw "testbed" / "banco de pruebas" mixed |
| menagerie (the metaphor) | **zoológico** | not "menagerie" — one image everywhere, incl. index & headings |
| the converter machine | **la máquina conversora** | one name everywhere |
| dashboard | **el panel** | not raw "dashboard" in prose |
| rollback (noun / verb) | **reversión / revertir** | not "rollback"/"hacer rollback" |
| snapshot (vSphere) | **instantánea** | not raw "snapshot" |
| timeout (in prose) | **tiempo de espera** ("se agota el tiempo") | not raw "timeout" |
| health check | **comprobación de estado** | not "health check" / "chequeo de salud" |
| library (code) | **biblioteca** | not "librería" (= bookstore) |
| to parse | **analizar / interpretar** | not "parsear" |
| gateway | **pasarela** | not raw "gateway" |
| add-on | **complemento** | not "add-on" |
| log (application) | **registro** | consistent with "registro de auditoría" |
| failover | **conmutación por error** (gloss failover at 1st use) | — |
| placeholder | **marcador** | not raw "placeholder" |
| workshop (the event) | **taller** | not raw "workshop" (URLs/paths stay) |
| Pod (object) | **Pod** (capitalized) | even in running prose |

Register: participant-facing material uses **tú** throughout; CONVENTIONS.md must
use tú too (not usted). Reader-facing password placeholders localized like the
mongodb lab: e.g. `tu-contraseña-analyst`, `TuContraseñaAquí`. Credential labels
follow the glossary targets (login: / password: / host: / database:).

### Spanish (es) — laptop-phase additions
| Concept | Español | not |
|---|---|---|
| presigned link/URL | **enlace prefirmado / URL prefirmada** | not presigned/presignado |
| to run (software/VM) | **ejecutarse / funcionar** | not "correr" |
| the lab (exercise, abbrev) | **el lab** (masculine) | not "la lab" |
| a catalog item | **un elemento del catálogo** | not "postura/posición" |
| the trailing path segment (tail) | **el sufijo / la parte final** | not "la cola" |
| the reader's machine | **la laptop** | not "portátil" (pick one: laptop) |
| named Secret object | **el Secret `<name>`** | keep English "Secret"; "un secreto" only for generic confidential data |
| monitoring | **monitoreo** | pick one (not mix with monitorización) |
