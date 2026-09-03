# Lab 5 · Infrastructure in Git

| | |
|---|---|
| **Time** | 40 minutes |
| **What it proves** | The cluster brings itself to whatever is written in Git, and holds that state |
| **What you'll need** | The cluster from lab 0, `kubectl`, `git`, a GitHub account, the `flux` CLI |

## Why this matters

The practice is over. From here on, it's a real task.

The business wants an internal service called **"Passes"**: an employee orders a visitor pass through a mobile app, security sees the list at the front desk, and management looks at a report once a month. You're on the platform team, and shipping this is your job.

The service will have several teams behind it, and there are three of you on the platform team. And this is where the reason this lab comes first in the working part begins.

**What happens when there are three admins.** Someone spun the app up through the dashboard. Someone tweaked the limits through `kubectl edit`, because it was the middle of the night and things were on fire. Someone changed the number of copies on Friday and forgot about it by Monday. A month later, nobody can answer two questions: **why is this setting the way it is** and **what should it be**. And when it all falls over, it turns out there's nothing to restore from — the state lived only in the cluster's head, and it vanished along with the cluster.

The cure for this isn't a policy, and it isn't "let's all agree not to touch things by hand." The cure is making touching things by hand **pointless**: the cluster will put it back the way it was. That's exactly what we're switching on today.

## Little glossary

| Term | What it is | Like… but |
|---|---|---|
| **Repository** | A set of files together with the full history of their edits: what changed, who changed it, and why | **A folder of templates on a shared drive**, but everyone has their own full copy rather than one shared by all |
| **GitOps** | An approach: the desired state lives in Git, and an agent running in the cluster carries it over there | **vRealize Automation with a blueprint**, but not a one-time application — a continuous reconciliation |
| **Flux** | That very agent. It runs inside the cluster | **A scheduled agent/script**, but not "apply and forget": it checks every minute and fixes any divergence |
| **Kustomization** | An object in the cluster: exactly what to apply from the repository | **A deployment job**, but don't confuse it with the `kustomize` utility — same name, different meaning |

The rest of this lab's words — Git, Commit, Branch, Pull request, Reconciliation, Drift, GitRepository, Prune — are introduced as we go, at the step where they're first needed. There's no need to memorize them now: apart from the action, they won't stick.

<details>
<summary><b>If you'd like to see the whole list at once</b></summary>

| Term | What it is | Like… but |
|---|---|---|
| **Git** | A store of text files with the full history of edits | **An archive of configs + a change log**, but it stores not copies of files but each change separately, with its author and reason |
| **Commit** | One saved change: what, who, why | **An entry in a change log**, but it stores the changed text itself, not just a mention that an edit happened |
| **Branch** | A parallel line of changes | no direct analogy; you need it to prepare a change without touching the working version |
| **Pull request** | A proposal to merge a branch, which someone reviews before it's applied | **Approving a request**, but the discussion is about specific config lines, not the general gist of the request |
| **Reconciliation** | The loop: read the desired state → compare it with the actual state → fix it | **The DRS logic that pulls the cluster toward a target state**, but what's reconciled isn't the placement of machines — it's everything that's been described |
| **Drift** | A divergence between fact and description | **A change made outside the template**, but here drift isn't "noted in a compliance report" — it's silently removed |
| **GitRepository** | An object in the cluster: where to take the state from | **The setting for a template source**, but the source is polled by itself on a schedule, not at the moment someone clicks "deploy" |
| **Prune** | The "delete from the cluster whatever has disappeared from Git" mode | no direct analogy; without it, deleting a file from the repository deletes nothing in the cluster |

</details>

## What's in the lab folder

All the files are already yours — you took them along with the repository. There's nothing to create or type out again: wherever it says `kubectl apply -f name.yaml` below, the file comes from here.

```bash
# From here on, all commands run from this folder: the paths in `kubectl apply -f` are relative to it.
cd labs/05-gitops
```

| File | What it is | When it comes in handy |
|---|---|---|
| `app/` | What should end up in the cluster: the namespace and the "Passes" service itself | you put it into your own Git repository |
| `flux/` | Two descriptions for Flux: where to take the repository from and what to apply out of it | you apply it to your own `lab` cluster |
| `check.sh` | A check that the cluster pulled the change from Git on its own | you run it at the end of the lab |

## Step 1. Setting up the repository

📍 **Where:** in the browser, on GitHub.

Create a new repository:

| Field | Value | Why |
|---|---|---|
| Name | `passes-gitops` | it makes clear this is the state of the service, not its source code |
| Visibility | **Public** | so that Flux can reach it without keys and you don't spend time on access |
| Add a README file | check the box | otherwise the repository will be empty, with no branch, and Flux will find nothing to read |

⚠️ **A public repository here is a deliberate simplification of the training testbed.** In production the repository is private, and Flux reaches it via a deploy key. That's another twenty minutes of fiddling with SSH keys, and today we're about something else. What will live in there — manifests without a single password — you'll see for yourself: passwords don't go into Git, and there's a separate lab for them.

📍 **Where:** on your laptop.

Pull the repository to your machine:

```bash
# clone = download the repository in full, together with its entire edit history. You get
# not access to a shared folder but your own full copy on disk: you can work with it offline.
# Replace `YOUR-LOGIN` with your own GitHub login, or the command will go to someone else's repository.
git clone https://github.com/YOUR-LOGIN/passes-gitops.git
# clone creates a folder named after the repository. From here on we work inside it.
cd passes-gitops
```

## Step 2. Putting the "Passes" service into the repository

📍 **Where:** on your laptop.

In this lab's folder there are two files: `app/namespace.yaml` and `app/passes.yaml`. Copy them into your repository, into the `apps` folder:

```bash
# apps — the folder Flux will pull descriptions from. We chose the name, and it's the exact
# same one named in the Flux configuration, so there's no reason to change it without cause.
#   -p  don't treat it as an error if the folder already exists
mkdir -p apps
# Copy both files into your own repository. Replace `/path/to/` with the place where you
# cloned the labs repository; `*.yaml` will take both files at once.
cp /path/to/labs/05-gitops/app/*.yaml apps/
```

Before sending them off, let's go over what you're putting in.

<details>
<summary><b>A closer look: what's inside namespace.yaml and passes.yaml</b></summary>

### `namespace.yaml` — a namespace of your own

```yaml
kind: Namespace
metadata:
  name: passes
```

A namespace is a logical partition inside a single cluster. The closest analogy in vSphere is a folder in the vCenter tree or a resource pool: the same resources, but a separate scope, separate rights, and separate quotas.

Why put it in Git together with the application rather than create it by hand: when the service eventually leaves the repository, Flux will also remove the namespace. No empty partition will be left behind that, six months later, nobody remembers why it was created.

### `passes.yaml` — the service itself

Four objects, separated by a `---` line.

**The first — a `ConfigMap` with the nginx configuration.** A `ConfigMap` puts a text file into the cluster separately from the application, and then that file is mounted inside the container. The point is to change the configuration without rebuilding the image.

Inside is an ordinary nginx config. One line deserves attention:

```
sub_filter '__POD__' '$hostname';
```

This tells nginx: in the page it serves, replace the text `__POD__` with the name of the machine where it's running. Inside a Pod, the machine name is the name of the Pod itself. That's how the page reports which copy served it. Later, by that name, you'll see that there are now two copies.

**The second — a `ConfigMap` with the page.** For now it's a placeholder: the real application shows up in the next lab, and today what matters isn't what the service displays but **where it came from** in the cluster.

**The third — a `Deployment`.** The description of the application: which image, how many copies, how to check readiness.

```yaml
spec:
  replicas: 1
```

How many copies to keep running. Note the wording: not "start one" but "keep one." This is the number we'll change through Git and watch what happens.

```yaml
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
```

The readiness check: the cluster knocks on this address and doesn't send traffic to a copy until it gets a response. Flux needs it too — we'll ask it to wait for readiness rather than report success right after applying.

**The fourth — a `Service`.** A permanent name that stands in front of all the copies. The link between the `Service` and the Pods is not a list of addresses but the condition `selector: app: passes`, that is, "all Pods with this label." A new copy with the label appeared — it's automatically brought under load balancing.

Not one of the four objects contains a password, a key, or a token. That's no accident: everything that gets into Git gets there forever — the history can be rewritten, but everyone who managed to clone it keeps the old copy. Secrets have no place here; there's a separate mechanism and a separate lab for them.

</details>

Send it to GitHub. Git remembers not everything indiscriminately, but what it was explicitly shown — which is why there are three commands, each doing its own thing:

```bash
# add = mark the files that will go into the next history entry.
git add apps
# commit = save what's marked as one entry: contents, author, time, and reason.
#   -m "..."  that very reason. It stays in the history forever, and people will read it.
# The commit lives only on your laptop for now — it's not yet in GitHub.
git commit -m "add passes service v1"
# push = send the accumulated commits to GitHub. Until this command, nothing there changes.
git push
```

**What you should see** — in the browser, on the repository page, the `apps` folder with two files. Meanwhile nothing has changed in the cluster yet: Git knows nothing about the cluster.

## Step 3. Installing Flux into your cluster

📍 **Where:** on your laptop.

Flux is several services inside your cluster. One reaches into Git and downloads the contents, another applies what was downloaded to the cluster and watches for divergences.

The cluster is yours, and you're its full administrator. You install it yourself; there's no need to ask the platform team.

First, the `flux` command-line tool. It lives on your laptop, not in the cluster: you'll use it to install the services and then to ask them about their state.

macOS:

```bash
# Homebrew takes the formula from the Flux project's repository and drops one executable file.
brew install fluxcd/tap/flux
```

Linux:

```bash
# The script from the Flux site detects your architecture and drops the file into /usr/local/bin.
#   -s          curl works silently, without a download indicator
#   | sudo bash the downloaded text is executed straight away with administrator rights — they're
#               needed because of the write into a system folder
curl -s https://fluxcd.io/install.sh | sudo bash
```

Windows (PowerShell, if Chocolatey is installed):

```powershell
# choco — a third-party package manager for Windows; it installs the same single flux.exe file.
choco install flux
```

Now we install the services themselves into the cluster:

```bash
# Set the access file: the command below creates objects in the cluster, and it matters in which one.
export KUBECONFIG=~/lab.kubeconfig
# flux install sets up a `flux-system` namespace in the cluster and deploys the services into it.
#   --components=...  which ones exactly to install:
#     source-controller     reaches into Git and keeps a fresh copy of the repository
#     kustomize-controller  applies what was downloaded to the cluster and watches for divergences
flux install --components=source-controller,kustomize-controller
```

⚠️ **Check where `KUBECONFIG` points before pressing Enter.** We're installing Flux into your own `lab` cluster, not the one it was handed to you from. If in doubt — `kubectl get nodes` should show one node with a name like `kubernetes-lab-md0-...`.

**What you should see** — a listing of what's being created, and at the end a line about a successful installation:

```
✔ install finished
```

We install only two of the four services. The full Flux set can also deploy Helm charts and send notifications to messengers — today that's not needed, and we have just one node with not much memory on it.

Make sure the services came up:

```bash
# -n flux-system — the namespace Flux settled into. Without this flag kubectl looks in the
# default namespace and shows nothing.
kubectl get pods -n flux-system
```

**What you should see** — two lines in the `Running` state.

<details>
<summary><b>If installing the <code>flux</code> CLI didn't work</b></summary>

The exact same thing installs with an ordinary manifest, without the tool:

```bash
# The same set of services, but as a ready-made description: -f accepts not only a path on disk
# but also a link. kubectl will download the file and apply its contents.
kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
```

The difference: this way all four services come up instead of two. That will show on memory, but the lab will still go through. Further on in the text the `flux ...` commands are needed only to look at the state — they can be replaced with `kubectl get gitrepository` and `kubectl get kustomization`, which show the same thing, just less neatly.

</details>

## Step 4. Pointing Flux at the repository

📍 **Where:** on your laptop.

Flux is installed, but it doesn't yet know where to go. We'll tell it, with two objects.

Open `flux/gitrepository.yaml` from this lab's folder and put in the address of **your** repository in place of the `REPLACE-ME` placeholder:

```yaml
  url: https://github.com/REPLACE-ME/passes-gitops
```

<details>
<summary><b>A closer look: what's inside gitrepository.yaml and kustomization.yaml</b></summary>

### `GitRepository` — where to take it from

```yaml
kind: GitRepository
spec:
  interval: 1m
  url: https://github.com/REPLACE-ME/passes-gitops
  ref:
    branch: main
```

This object's only job is to keep a fresh copy of the repository. It applies nothing to the cluster, it only downloads.

`interval: 1m` — how often to go for updates. A minute is chosen for the lab, so you don't have to wait. In production it's usually set to between one and five minutes, and an instant reaction to a push is done not by shrinking the interval but with a webhook: GitHub itself knocks on the cluster when something has changed.

`ref: branch: main` — which branch to treat as the source of truth. Everything merged into `main` will travel to the cluster. Everything in other branches will not. This is where review comes from: a change first lives in its own branch, where it can be looked at, and only merging into `main` makes it take effect.

### `Kustomization` — what to apply

```yaml
kind: Kustomization
spec:
  interval: 1m
  path: ./apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: passes
  wait: true
```

`path: ./apps` — the folder inside the repository. Everything in it will travel to the cluster. Files next to it — for example a `README.md` in the root — won't be touched.

`interval: 1m` here doesn't mean the same thing as in `GitRepository`. There it's "how often to download." Here it's **how often to reconcile the cluster's actual state against the described one**. Even if nothing changed in Git, once a minute Flux checks whether the cluster matches the description and brings it into line. This is exactly what we'll get caught on a little further into the lab.

`prune: true` — delete from the cluster the objects that have disappeared from Git. Without this, Git stops being a full description: you delete a file from the repository, but the object keeps running in the cluster, and six months later nobody understands where it came from. With `prune`, description and reality match in both directions.

`wait: true` — don't report success right after applying, but wait until what was applied becomes ready. The difference is exactly the same as between "submitted the request" and "the request is done."

</details>

Apply both:

```bash
# -f points at a folder, not a file: all the manifests in it will be applied —
# both GitRepository and Kustomization. Both are created in the flux-system namespace.
kubectl apply -f flux/
```

Let's see what came of it:

```bash
# We ask Flux about the reconciliation state.
#   --watch  keep the window busy and refresh the line as things change
# READY: True means the repository's contents reached the cluster and were applied.
# REVISION — the branch and the short identifier of the commit currently applied.
flux get kustomizations --watch
```

**What you should see** — after a few dozen seconds, the `Ready: True` state and the hash of the commit that's applied:

```
NAME     REVISION            SUSPENDED  READY  MESSAGE
passes   main@sha1:a1b2c3d   False      True   Applied revision: main@sha1:a1b2c3d
```

Stop watching with `Ctrl+C` and look at what showed up in the cluster:

```bash
# all — a shorthand for the main object types at once: Pods, Deployment, Service, and the rest.
# You didn't create the `passes` namespace by hand: it arrived from the repository along with the application.
kubectl get all -n passes
```

**You applied nothing by hand.** You put text into GitHub, and the cluster pulled it in on its own. The difference between this and `kubectl apply -f` isn't convenience — it's that now there's a single place where it's written how things should be.

## Step 5. The first change through `git push`

📍 **Where:** on your laptop, in the repository folder.

One copy isn't enough for the "Passes" service: security watches the list around the clock, and updating the application shouldn't take the front desk down. Let's set two.

Before, you'd have run `kubectl scale`. Now — an edit in the file.

Open `apps/passes.yaml` and change:

```yaml
spec:
  replicas: 2
```

Send it off:

```bash
# The same three steps as in the first send: mark the file, save with a reason, send.
git add apps/passes.yaml
git commit -m "passes: two replicas so the gate does not go dark during rollout"
git push
```

Now watch the cluster and wait:

```bash
# -w = "watch and keep appending": the window stays busy, a new line appears every time
# the state of the copies changes. Exit with Ctrl+C.
kubectl get pods -n passes -w
```

**What you should see** — within a minute a second copy appears. You didn't create it.

Don't want to wait a minute — you can ask Flux to reconcile right now:

```bash
# reconcile = "reconcile right now, without waiting for the next minute."
#   kustomization passes  which object to reconcile
#   --with-source         first go to Git for the fresh commit and only then apply;
#                         without this flag the reconciliation goes off the copy downloaded earlier
flux reconcile kustomization passes --with-source
```

Note the commit message. `two replicas so the gate does not go dark during rollout` — that's the reason. Six months from now, when someone asks "why are there two here and not one," the answer is found in five seconds:

```bash
# log = the history of commits, freshest on top.
#   --oneline         one line per commit: a short identifier and the reason text
#   apps/passes.yaml  show only the commits that touched this exact file
git log --oneline apps/passes.yaml
```

Neither the dashboard nor `kubectl` leaves a trace like this.

## Step 6. Let's check that everything's under control

📍 **Where:** on your laptop.

Night, an incident, the service is short on copies. You do what you always did:

```bash
# Change the number of copies right in the cluster, bypassing Git — as you did until today.
#   -n passes  the application lives in this namespace; without the flag the command won't find it
kubectl scale deployment passes -n passes --replicas=5
```

```
deployment.apps/passes scaled
```

It worked. Let's check:

```bash
# The READY column reads as "ready/ordered": how many copies respond and how many there should be.
kubectl get deployment passes -n passes
```

Five copies. Wait a minute and look again:

```bash
# The same command. The only difference is that a minute passed between the two runs.
kubectl get deployment passes -n passes
```

**What you'll see:**

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
passes   2/2     2            2           8m
```

Two copies again. Your command was carried out and then undone.

> **Stop and think before reading on.**
>
> Who undid it? Why did it happen silently, without a single error in response to your command?
> And most importantly: is this a breakage that needs fixing, or is it working as intended?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

Flux undid it, and that's exactly what it was installed for.

Once a minute the `Kustomization` takes what's in Git and compares it with what's in the cluster. Git says `replicas: 2`. The cluster turned out to have `5`. A divergence — which means the cluster is wrong, because it isn't the source of truth.

**Why `kubectl scale` didn't return an error.** It couldn't have: it honestly did exactly what it was asked. Kubernetes accepted the change, the copies really did come up. A minute later the reconciliation came and restored the described state. Nobody argued with anyone — different mechanisms each worked by their own rules.

**Why this is a feature, not a bug.** Go back to the pain the lab started with: there are three of you, someone changed something by hand, and nobody knows what's set where. Now that doesn't happen. A change made outside Git lives until the next reconciliation — that is, it doesn't live. Three things follow from this:

1. **The cluster can't be quietly misconfigured.** Not "it's frowned upon," but physically impossible.
2. **Git always describes reality.** Not "should describe" — it does describe, because divergence removes itself.
3. **Restoring the cluster becomes a boring procedure.** Install Flux, give it the repository, wait. Everything that was there comes back, because it's all written down.

**The lesson is broader than this error.** You've just seen the difference between "apply and forget" and "reconcile constantly." An ordinary `kubectl apply` is a shot: the state changed and then lives on its own, and anyone can nudge it. Reconciliation isn't a shot but a pull: the description constantly draws reality toward itself.

The very same mechanism, by the way, fixes mistakes that aren't yours too. If a node failure deletes a Pod or someone accidentally wipes the `Service` — that comes back as well.

**When it gets in the way.** It gets in the way during an incident, when you really do need to change something immediately and there's no time to discuss. For cases like that, Flux can pause:

```bash
# suspend = pause reconciliation for this object. Flux stops bringing the cluster to the
# description, and manual changes start to live. The contents of Git don't change meanwhile.
flux suspend kustomization passes
```

After this, reconciliation doesn't run, and by hand you can do anything. To reverse it:

```bash
# resume = turn reconciliation back on. The very next reconciliation removes everything done by hand.
flux resume kustomization passes
```

⚠️ Pausing is a deferred debt: while the `Kustomization` is paused, Git again stops describing reality, and you're back exactly where you started. There's one rule: paused — set yourself a reminder to turn it back on.

</details>

## Step 7. Rolling back through `git revert`

📍 **Where:** on your laptop.

Now a real situation. You roll out a change, and it turns out to be bad.

Make an edit: let's say someone, without thinking, squeezes the memory down to an unworkable value. In `apps/passes.yaml`, change the memory limit:

```yaml
          resources:
            requests:
              cpu: 20m
              memory: 4Mi
            limits:
              cpu: 300m
              memory: 4Mi
```

Send it. A knowingly bad change travels the same path as a good one: right now there's no check between your `push` and the cluster — and that's the point of this step.

```bash
# The same add, commit, push. The reason in the commit is written honestly — it'll come in handy
# in five minutes, when the change has to be undone.
git add apps/passes.yaml
git commit -m "passes: trim memory limit"
git push
```

We wait and watch:

```bash
# Watch the copies until the reconciliation brings the new description.
kubectl get pods -n passes -w
```

**What you should see** — new copies don't come up. The `OOMKilled` state means the process was killed for exceeding the memory limit; `CrashLoopBackOff` means the cluster has already restarted the copy several times in a row and now waits longer and longer before the next attempt. Nginx doesn't fit into four megabytes and dies right after starting.

```bash
# The same list, but as a single snapshot, without watching.
kubectl get pods -n passes
```

```
NAME                      READY   STATUS             RESTARTS   AGE
passes-6c9d4f7b8-2xk4n    1/1     Running            0          12m
passes-7f8a1b2c3-qq7lp    0/1     CrashLoopBackOff   3          90s
```

The old copy is still running — the service is alive, but the update has stalled. Time to roll back.

**How you'd have rolled back before:**

```bash
# undo would return the Deployment to the previous revision — to the settings from before the edit.
kubectl rollout undo deployment/passes -n passes
```

This command will work. The copies will return to the previous image and the previous settings, and in twenty seconds all will be well — right up until the moment Flux reconciles with Git. And in Git it still says `memory: 4Mi`. Within a minute the broken state comes back.

**Don't do `rollout undo`. Roll back where the truth lives** — in Git:

```bash
# revert = add a new commit that undoes the changes of the specified one.
#   HEAD       "the last commit of the current branch" — the very one with the bad limit
#   --no-edit  don't open an editor for the commit message; Git writes the header itself
git revert --no-edit HEAD
# Until the reverting commit is sent to GitHub, Flux knows nothing about it.
git push
```

**What you should see** — a new commit with the header `Revert "passes: trim memory limit"`, and within a minute two working copies in the cluster again.

```bash
# The copies come up again: the working memory limit is back.
kubectl get pods -n passes
# And here you can see which commit is applied now — it should match the reverting one.
flux get kustomizations
```

<details>
<summary><b>How <code>git revert</code> differs from "put it back the way it was"</b></summary>

`git revert` doesn't erase the bad commit. It adds a **new** commit that undoes the bad one's changes. Everything stays in the history: what was broken, when it was noticed, and what was rolled back.

```bash
# -4 — show the four most recent commits; the top one is the freshest.
git log --oneline -4
```

```
9f3c1ab Revert "passes: trim memory limit"
5d2b8e0 passes: trim memory limit
c71a4f9 passes: two replicas so the gate does not go dark during rollout
0e5f2d3 add passes service v1
```

Compare this with how it looks without Git. A month later the question "wait, have we already stepped on this rake?" has no answer: `kubectl rollout undo` leaves no trace, and the `Deployment`'s revision history keeps the last ten and dies together with the object.

Here you have four lines from which you can see: yes we did, here's when, here's who, here's what exactly they did, here's how long it lived before the rollback.

**There's also a second command — `git reset`, which really does erase history.** In a shared repository it isn't used: a commit you erased on your machine is still on two colleagues' machines, and their next `push` brings it back. Undoing in a shared branch is always `revert`.

</details>

## Step 8. Review through a pull request

📍 **Where:** in the browser, on GitHub.

The last part of the pain we're curing: a change traveled to the cluster immediately, and nobody looked at it. The bad memory limit from the previous step would have failed review in ten seconds — but there was no review.

Start a branch for the change:

```bash
# checkout -b = start a new branch and switch to it right away. A branch is a separate line
# of changes: commits made in it don't reach `main`, and therefore don't reach the cluster either.
#   passes/version-line  the branch name; a slash in the name is allowed and serves for grouping
git checkout -b passes/version-line
```

In `apps/passes.yaml`, change the page's line — for example, the version in the text from `v1` to `v1.1`. Send the branch:

```bash
git add apps/passes.yaml
git commit -m "passes: bump the version shown on the page"
# origin — the name under which Git remembers the address you cloned the repository from.
#   -u origin passes/version-line  create a branch of the same name in GitHub and remember
#                                  the link with it, so that a bare `git push` is enough later
git push -u origin passes/version-line
```

In response GitHub prints a link to create a pull request. Open it.

**Look at the "Files changed" tab.** This is what infrastructure review is: not "Pete says he fixed the limits," but concrete lines — before and after, highlighted. Your colleague sees exactly what will travel to the cluster and can leave a comment on a specific line.

The cluster meanwhile hasn't changed, and won't: `GitRepository` looks at the `main` branch, and the change lives in a different branch.

Click **Merge pull request** — the change lands in `main`, and the next reconciliation brings it to the cluster. In a minute we open a tunnel and look at what the service serves:

```bash
# port-forward = a temporary tunnel from your laptop into the cluster.
#   -n passes     the namespace the service lives in
#   svc/passes    where we lead: to the Service, not a specific copy
#   8080:80       on the left the port on your laptop, on the right the service's port inside the cluster
kubectl port-forward -n passes svc/passes 8080:80
```

📍 **In the browser** <http://localhost:8080> — the page says `v1.1`. Close the tunnel with `Ctrl+C`.

The full route of a change is now this: **branch → pull request → review → merge → cluster**. At no step did anyone enter the cluster by hand.

<details>
<summary><b>What of this is done in production that we didn't do</b></summary>

Three things that a working repository adds on top:

**Branch protection.** In the GitHub settings the `main` branch is closed to direct pushes, and the only way in is a pull request with an approval. Otherwise discipline rests on good faith, and good faith breaks at three in the morning.

**Checks before the merge.** Automation checks the manifests for syntax and for policy compliance before they travel to the cluster, and doesn't let broken ones be merged.

**Several environments.** Usually the repository holds not one folder but `apps/staging` and `apps/production`, each with its own `Kustomization` in its own cluster. A change first travels to staging, settles, then to production.

We didn't do this because each thing is a separate hour, and the mechanics don't change because of them: the source of truth is still Git, and Flux still pulls the cluster toward it.

</details>

## Verification

📍 **Where:** on your laptop, in the same terminal window where you worked with `kubectl`.

```bash
# Return to the lab folder: the script lives there, and you worked in your own repository's folder.
cd labs/05-gitops
export KUBECONFIG=~/lab.kubeconfig
# The script changes nothing in the cluster: it only reads the state and prints a report.
./check.sh
```

⚠️ **On Windows the script runs from WSL**, not from PowerShell — how to install it is written at the start of lab 0. Without WSL you can still complete the lab, but there'll be no report artifact.

The script checks not the fact that Flux is installed, but that the mechanism works: the Flux services are alive, the source points at your repository and reads from it successfully, the objects in the cluster really do belong to Flux (rather than having been applied by hand), the service responds over HTTP, and reconciliation isn't paused.

If you'd like the script to also look at your repository's history — show it where the clone lives:

```bash
# LAB_REPO — the variable from which the script learns where the clone of your repository lives.
# Put in your own path if you cloned it somewhere other than the home folder.
export LAB_REPO=~/passes-gitops
./check.sh
```

Then it will additionally verify that the commit applied in the cluster matches the latest one in your branch, and that the rollback was done through `revert`.

## Cleanup

We delete nothing: the repository and Flux will be needed later — the next services will arrive in the cluster the same way.

When you're done with all the labs, you can remove everything at once like this:

```bash
# delete kustomization = remove the reconciliation object from the cluster.
#   --silent  don't ask for confirmation again
flux delete kustomization passes --silent
```

Because of `prune: true`, everything the `Kustomization` brought will leave along with it: the application, the settings, and the `passes` namespace itself. Nothing has to be listed by hand and nobody forgets a leftover — because Flux keeps the list of what was created for itself.

This, by the way, is a separate benefit of GitOps that isn't noticed right away. Fully deleting a service is a `git rm` of the folder and a `push`.

## What we can do now

- Keep the cluster's state in Git and understand how that differs from `kubectl apply`
- Install Flux into our cluster and point it at a repository
- Explain what reconciliation is and why a change made outside Git doesn't survive
- Roll back through `git revert` rather than through `kubectl rollout undo`
- Take an infrastructure change through a pull request and review

## And in vSphere this would be

The closest analogy is a blueprint in vRealize Automation: the desired configuration is described separately and deployed from the description. But from there the paths diverge. A blueprint deploys and lets go; if someone then goes into vCenter and changes a machine's memory, the blueprint won't learn of it. Compliance tools will show the divergence in a report — and that's it, a human goes to resolve it.

Here the divergence resolves itself, every minute, without a report and without a human.

The second difference is about history. In vCenter there's a task log: who did what and when. It answers the question "what happened," but doesn't answer "why" and "how it should be." Git has both: the text of the change, the author, the reason in the commit message, and the discussion in the pull request.

**Where vSphere is more convenient, honestly.** Three things.

**The barrier to entry.** To change a virtual machine's memory in vCenter, you need to know how to use vCenter. To change it here, you need to know how to use Git: branches, commits, merges, conflicts. For someone who doesn't know Git, this isn't "more convenient" — it's a new profession, and for the first two weeks they'll work more slowly than they used to.

**Reaction speed.** In an emergency you want to change the state now, not through a branch, a review, and a minute of reconciliation. The pause mechanism exists, but you have to remember to use it and remember to turn it off.

**Clarity of failure.** When something doesn't deploy in vCenter, you're shown a task with an error. When it doesn't deploy here, you have to look at the `GitRepository`'s state, then the `Kustomization`, then the events, then the logs of two services. Diagnostics are spread across layers, and that's honestly inconvenient until you get used to it.
