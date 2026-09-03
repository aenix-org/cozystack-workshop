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
