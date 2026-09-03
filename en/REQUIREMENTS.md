# Environment requirements

For anyone setting up the environment for the workshop, or for working through the
labs on their own. Participants don't need this file.

## Tenant quota

**At least 40 CPUs and 48 GB of memory per tenant.**

The reason is how the request quota is calculated: it equals one tenth of the limit.
A tenant with `cpu: 16` gets 1600m of requests — while a single lab cluster from lab 0
takes up about 1435m. That leaves nothing for the managed services in labs 6–12, and
lab 0 explicitly asks you not to delete the cluster.

The symptom when you run short: `exceeded quota: tenant-quota` in the events, and a
cluster stuck forever in status `Unknown`. It will not come out of that state on its own.

## Creating tenants

**One at a time, not in a batch.**

Several simultaneous creations with storage and monitoring enabled clog the helm-controller
queue: releases fall into an install–fail–delete cycle with ten-minute timeouts. You
diagnose it by `observedGeneration: -1` on the stuck HelmRelease.

The same goes for deletion: a tenant with a cluster inside takes minutes to tear down,
because the cleanup job waits for the worker virtual machines to be released.

## What must be enabled in the tenant

| What | Why | Labs |
|---|---|---|
| etcd | Without it the cluster from lab 0 won't come up | all |
| Storage (SeaweedFS) | Buckets and Harbor | 6, 11 |
| Monitoring | Metrics and dashboards | 3, 14 |

`metrics-server` is installed automatically if the tenant has etcd — you don't need to
enable it separately. It lives in the `cozy-monitoring` namespace, but it isn't part of
the monitoring add-on.

## Platform version

The labs were written and verified on **Cozystack v1.6.1**. On earlier versions some
catalog entries have a different name or a different set of fields.
