## 8. Logging into the bastion

**One login, and you're already in the cluster**

📍 **Where:** open the dashboard in the browser; everything else happens over SSH on the bastion.

**Your credentials** (login and password are the same in all three places):
```
dashboard: https://dashboard.workshop.aenix.io
bastion:   ssh workshopXX@<bastion-address>
login:     workshopXX      ← your number, I'll tell you in person
password:  ...             ← I'll tell you in person
```

Log into the bastion — the password is the same as for the dashboard, **no SSH key needed**:

```bash
ssh workshopXX@<bastion-address>
```

Once inside, access to the cluster is already set up: the kubeconfig lives in `~/.kube/config`, and `kubectl`
sees your tenant right away. **No browser opens for this** — logging into the cluster goes through a
token, without Keycloak. Let's check:

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

The first command shows `tenant-workshopXX`; the second answers `No resources found`. That's the
right answer: there are no machines yet, but the cluster recognizes you.

⚠️ `kubectl get vm` and `kubectl get vmi` won't work — under your account the `vminstance` type is
what's available. That's by design.

⚠️ The dashboard in the browser (for the point-and-click steps) uses the same login and password. But
the kubeconfig from the dashboard (`Info → Secrets → kubeconfig-tenant-workshopXX`) does **not** need to
be downloaded onto the bastion: there it's meant for browser-based login, while the bastion already has
a ready-made one that works without it.
