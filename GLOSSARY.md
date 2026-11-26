# Glossary — canonical terminology

This table fixes how key terms are handled so both languages read consistently
and no term drifts. Two rules override everything else:

1. **Product, project and CLI names are never translated or transliterated** —
   in any language they stay exactly as written here.
2. **Kubernetes object and command names stay in English** even in Russian
   prose (this is what real localized Kubernetes documentation does).
   Translate the *idea* around them, not the identifier.

## Never translated — keep verbatim in both languages

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

| Concept (ru) | English |
|---|---|
| кластер | cluster |
| control plane | control plane |
| узел (node) | node |
| тенант | tenant |
| манифест | manifest |
| применить (kubectl apply) | apply |
| реконсиляция / сводит к желаемому | reconcile / reconciliation |
| самолечение | self-healing |
| автомасштабирование | autoscaling |
| выкатка / раскатка | rollout |
| образ | image |
| диск | disk |
| сеть | network |
| хранилище | storage |
| виртуалка / виртуальная машина | virtual machine (VM) |
| контейнер | container |
| управляющий кластер | management cluster |
| учебный кластер `lab` | lab cluster `lab` |
| виртуалка-bastion / джамп-хост | the bastion (shared VM) |
| дашборд | dashboard |
| квота | quota |
| секрет (объект) | Secret |

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

## Placeholders, scripts and manifests: English only, in both languages

There is one copy of every script, manifest, SQL file and app source: the one in
`en/`. Every other language folder carries byte-identical copies, and fenced code
blocks in the guides match the `en/` guide. Placeholders are never localized,
neither in files nor in inline code in the prose. The table maps the old Russian
placeholders to the English ones now used everywhere:

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

Functional tokens: `workshopXX`, `PASTE_PRESIGNED_URL` and the `PASTE_...` fields
in `convert.sh` (formerly `ВСТАВЬТЕ_...`). When a guide quotes a script, its output
or a placeholder, quote the English text exactly as it is in the file.
