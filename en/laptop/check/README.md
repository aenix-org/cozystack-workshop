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

### If you're on Windows

The scripts are written in bash and won't run on Windows itself. You need **WSL** — a Linux
subsystem that installs with a single command in an Administrator PowerShell:

```powershell
wsl --install
```

The computer will ask to reboot; afterwards an Ubuntu console opens. From there everything
is the same as for everyone else, only inside WSL you need your own `kubectl`:

```bash
sudo snap install kubectl --classic
```

The credentials for the lab cluster — that same `lab.kubeconfig` you created in lab 0 — are
found by the script through the `KUBECONFIG` variable. If you saved it inside WSL, the path
is the usual one:

```bash
export KUBECONFIG=~/lab.kubeconfig
```

If you saved it on the Windows drive, there's no need to copy it into WSL — the drives are
visible from inside under `/mnt/c/...`. Substitute your Windows username and the folder where
you saved it:

```bash
export KUBECONFIG=/mnt/c/Users/<your-name>/lab.kubeconfig
```

⚠️ **If WSL can't be installed** — a common situation on a corporate laptop — you can still
do the labs in full, all except the automated check. In that case you won't get the artifact
report: ask a colleague on Linux or macOS to run the script against your kubeconfig, or
attach to your application the command output from the "Check" section of the corresponding
lab.

The script figures out where to look on its own, via the `KUBECONFIG` variable. If it's not
set, it tells you so and stops.

For labs that need access to a tenant on the management cluster, you also need the
`COZY_TENANT` variable — the name of your tenant, for example `workshop07`:

```bash
export COZY_TENANT=workshop07
./check.sh
```

## What you get out of it

In the terminal — one line per check:

```
[  OK  ] приложение развёрнуто и отвечает
[  OK  ] имя пода подставляется в страницу
[ FAIL ] автомасштабирование не настроено
         не найден HorizontalPodAutoscaler для deployment/rickroll
         подсказка: примените hpa.yaml из этой папки
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
