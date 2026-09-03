# Check scripts

Every lab folder contains a `check.sh`. It verifies that the lab is actually done —
not that "a file was applied," but that it **works in substance**.

You run it yourself, whenever you like. The result is a report in the terminal and an
artifact file you can attach anywhere: the community chat, a certification application, your
own notes.

## How to run it

```bash
cd labs/03-scale
./check.sh
```

You're on the bastion (Linux) — `bash`, `kubectl`, and everything else you need are already
there; nothing to install. The credentials for the lab cluster — that same
`lab.kubeconfig` you created in lab 0 — are found by the script through the `KUBECONFIG`
variable:

```bash
export KUBECONFIG=~/lab.kubeconfig
```

> If you're doing the labs not on the bastion but from your own Windows machine — how to
> install WSL and where to get `lab.kubeconfig` is described in the laptop kit:
> [`../../laptop/check/README.md`](../../laptop/check/README.md).

The script figures out where to look on its own, via the `KUBECONFIG` variable. If it's
not set, it tells you so and stops.

For labs that need access to a tenant on the management cluster, you also need the
`COZY_TENANT` variable — the name of your tenant, for example `workshop07`:

```bash
export COZY_TENANT=workshop07
./check.sh
```

## What you get out of it

In the terminal — one line per check:

```
[  OK  ] application deployed and responding
[  OK  ] Pod name is injected into the page
[ FAIL ] autoscaling is not configured
         no HorizontalPodAutoscaler found for deployment/rickroll
         hint: apply hpa.yaml from this folder
```

⚠️ **The report is written into the lab folder and carries the date and time.** If the
repository is shared or you've run the check several times, several files will pile up there
— look at the time in the name so you don't mistake someone else's run, or an earlier one,
for your own.

Alongside it appears a file `report-<lab>-<date>.md` — the same result in Markdown, together
with the collected evidence: versions, command output, object names. That's the artifact.

## Requirements for the script's author

**Check substance, not the fact of application.** Bad: "a Deployment object exists." Good:
"the application responds over HTTP and the response contains the Pod's name."

**Every failure explains what to do.** A `FAIL` line without a hint is defective. The reader
runs the script precisely because they're stuck.

**The script neither fixes nor creates.** It only reads. The one exception is a temporary
Pod for testing network reachability, which cleans up after itself.

**Works on macOS and Linux.** No GNU-specific `sed -i`, `readlink -f`, `date -d`. Test on
both systems.

**Doesn't stop at the first error.** It runs every check and shows the full picture.
Don't use `set -e`.

**Doesn't print passwords or tokens.** If a value is secret, write `<hidden>`.

**Idempotent.** Running it ten times in a row doesn't change the cluster's state.

## Shared library

`check/lib.sh` — shared functions, sourced at the start of every script:

- `ok "text"` / `fail "text" "hint"` / `warn "text"` — print a result
- `need_kubeconfig` — check that `KUBECONFIG` is set and the cluster responds
- `need_tenant` — check that `COZY_TENANT` is set
- `evidence "heading" "value"` — add a piece of evidence to the artifact
- `finish` — sum up, write the report, return the exit code

Exit code: `0` — everything passed, `1` — there are failures. That way the script can be used
in automation.
