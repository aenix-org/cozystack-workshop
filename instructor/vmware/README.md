# Host tooling: VMware → Cozystack workshop

`provision-vmware.sh` prepares participant environments for the workshop in `en/laptop` / `en/bastion` (and the Russian copies), one after another:

```bash
WORKSHOP_REF=master ./provision-vmware.sh vmw01 vmw02 vmw03
```

For each login it creates, idempotently:

- a Cozystack tenant (`monitoring: false`, quota 40 CPU / 48Gi);
- a Keycloak user in the tenant's `super-admin` group;
- a GitLab user and the project `<login>/vmware-migration` with an empty `platform/` folder, plus a read-only deploy token;
- Flux in the tenant namespace: `GitRepository infra` and `Kustomization platform` (`prune: true`, applied as the tenant service account);
- the `workshop-vmware` Role (read Secrets, `pods/exec`, Services and Ingresses, Flux and HelmRelease status, DataVolumes, VM live migration) and read access to instance types, bound to the participant's group and to the tenant service account;
- on the bastion: a Linux user, the cloned repository, a kubeconfig for the tenant (`api.workshop.aenix.io`), this repository checked out at `WORKSHOP_REF` as `~/workshop`, and `~/credentials.txt`.

`STEP=platform|bastion|all` runs part of it, `DRY_RUN=1` prints the plan. Passwords and tokens are kept in `../state/` next to the scripts (mode 600) and are never printed; keep that folder, because re-runs reuse it. The script never deletes anything.

Requirements: `~/workshop.txt` with the `admin@workshop` context, SSH access to the bastion as `ubuntu`, and a GitLab admin token in the file named by `GITLAB_ROOT_TOKEN_FILE`.

## Before a workshop

- **Node image.** VMs pause with `PausedIOError` when LINSTOR converts a diskless replica to diskful under a running VM on DRBD 9.2.16 (Talos 1.12.x), see [cozystack#3168](https://github.com/cozystack/cozystack/issues/3168). It happens to some VMs about half an hour after they start or move, and it breaks part 6. Run the workshop on nodes with DRBD 9.3.x (Talos 1.13, Cozystack 1.4 and later); `virtctl restart` is the workaround.
- **Memory.** Each participant holds an 8 GiB conversion VM during part 2, then a 2–4 GiB VM, PostgreSQL ×2 and Kafka. A live migration needs room for a second copy of the VM on another node. Count memory requests, not usage.
- **Disk from image.** Keep the conversion disk exactly the image size: a larger clone hangs on this LINSTOR version ([cozystack#5460](https://github.com/cozystack/cozystack/issues/5460)).
- **Public IPs.** `external: true` on VMs goes through robotlb and the Hetzner Cloud API, which rate-limits; the workshop publishes through the platform ingress instead.
