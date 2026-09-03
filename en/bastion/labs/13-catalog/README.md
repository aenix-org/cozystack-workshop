# Lab 13 · Your own application in the Cozystack catalog

| | |
|---|---|
| **Time** | 40 minutes |
| **What it proves** | The platform catalog is open: your own application takes its place in it, right next to Redis and the VMs |
| **What you need** | `helm` on the bastion, `kubectl`, tenant access. The `lab` cluster is not needed here |

## Why this matters

The "Guest Pass" is up and running. A week later the subsidiary hears about it — they have
the same reception desk and the same problem. A week after that, the second subsidiary
comes calling.

To the first two you explained it by word of mouth: which images, which config, which
parameters, what to bring up first. By the third time it was clear this could not go on.
The explanation lives in one person's head, there is only one such head, and there will be
five companies.

What you need is for "Guest Pass" to show up for them the same way Redis did: an entry in
the catalog, a form with parameters, a button. Without you.

This is the finale of the workshop. We have walked the road from "deploy me a Pod" to
"here is a platform with our service inside it."

## First things first: where your permissions end

This lab will **not** deploy the application into the catalog. And that is not because we
ran out of time to write the part that would.

The `ApplicationDefinition` object, the one that registers an application in the catalog,
is **cluster-scoped**: there is one per cluster, it has no namespace, and it changes the
catalog for every tenant at once. A tenant cannot create such an object. Check for
yourself, right now: you can ask the cluster about your permissions without creating
anything.

```bash
# KUBECONFIG — the variable kubectl reads to find the cluster's address and your credentials.
# Here it is the tenant access, the same file as in every other lab.
export KUBECONFIG=~/.kube/config
# auth can-i = "am I allowed to?". The cluster answers yes or no and changes nothing:
#   create                   which action we are checking
#   applicationdefinitions   on which type of object
kubectl auth can-i create applicationdefinitions
```

**What you will see:**

```
no
```

There is no workaround here, and none is intended. So the lab is set up honestly: **you
write the chart and the application definition, verify them locally, and hand them to the
platform admin.** That is exactly how it works in real life: building the catalog and
running it are different roles.

An analogy from the familiar world: you prepare the contents of the OVF template, but it
is placed into the shared Content Library by whoever holds the rights to that library.

## Little glossary

| Term | What it is | Like… but |
|---|---|---|
| **Helm** | A manifest templating tool with parameters and versions | closest to an OVF template with input fields, but as text and in Git |
| **Chart (chart)** | A Helm package: templates, default values, schema | an **OVF template**, but deployed many times with different parameters in one place |
| **Release (release)** | A specific deployment of a chart under its own name | a **VM deployed from a template**, but it remembers its version history and can roll back |
| **values** | The parameters a chart is deployed with | the **fields of the OVF deployment wizard**, but plain YAML, kept in Git alongside everything else |
| **values.schema.json** | A description of the allowed values | **field validation in the wizard**, but it checks before applying, not during |
| **ApplicationDefinition** | An entry in the platform catalog: what to show and what to deploy | an **entry in the Content Library**, but one per cluster and visible to all tenants |
| **Namespace** | A section of the cluster where one owner's objects live | a **folder or resource pool**, but the boundary of permissions runs along it: your tenant is a namespace |
| **Cluster-scoped** | An object with no namespace, shared across the whole cluster | a **vCenter-level setting**, but the rights to it belong to the platform team, not the tenant |
| **CRD** | The way to add a new type of object to Kubernetes | once registered, your type is indistinguishable from the built-in ones |

## What is in the lab folder

Every file is already there — you got it together with the repository. There is nothing to
create or type out again: wherever it says `kubectl apply -f name.yaml` below, the file is
taken from here.

```bash
cd labs/13-catalog
```

| File | What it is | When it comes in handy |
|---|---|---|
| `chart/` | Your application, packaged for the catalog: templates, values, form-field schema | you read and verify it locally |
| `applicationdefinition.yaml` | The description of the catalog entry: what it is called and what to show in the dashboard | you try to apply it, to see the permission denial |
| `guestpass-example.yaml` | What ordering your application will look like once it is published | you read it; you can only apply it after publication |
| `icon.svg`, `icon.b64` | The entry's icon — the source and the same thing as a string; already embedded in the definition | comes in handy if you ever change the icon |
| `check.sh` | A check that the chart renders and the cluster accepts it | you run it at the end of the lab |

## Step 1. Look at what we are packaging

The `chart/` folder holds a finished "Guest Pass" chart. The application inside is
deliberately simple — nginx with a page — because the lab is not about the application, it
is about the packaging.

```
chart/
├── Chart.yaml            name, version, description
├── values.yaml           parameters and default values
├── values.schema.json    which values to consider valid
└── templates/
    ├── configmap.yaml    the page and the nginx config
    ├── deployment.yaml   the application itself
    └── service.yaml      the address
```

<details>
<summary><b>A closer look: what's inside the chart</b></summary>

### `Chart.yaml` — the passport

```yaml
name: guest-pass
version: 0.1.0
appVersion: "1.0"
```

Two different version numbers, and they are constantly confused.

`version` is the version of the **chart**, that is, of the packaging. Tweaked a template,
added a parameter, fixed a typo in the description — bump it.

`appVersion` is the version of the **application** inside. It changes when a new version of
"Guest Pass" itself comes out, and it has no connection to the packaging version.

The practical point: from `version` the admin can tell whether the deployment mechanism
itself is being updated, and from `appVersion` whether what people actually use is being
updated.

### `values.yaml` — the parameters

```yaml
## @param {int} replicas=2 - Number of application replicas.
replicas: 2

## @param {string} greeting=Order a pass for your guest - Text shown on the main page.
greeting: "Order a pass for your guest"

## @param {bool} external=false - Enable external access from outside the cluster.
external: false
```

The `## @param` comments are not decoration and not documentation for humans. From them the
Cozystack generator (`cozyvalues-gen`) builds `values.schema.json` and the parameter table
in the chart's README. One source of truth: change the comment, regenerate the schema, and
the form in the dashboard changes with it.

The format is strict: `## @param {type} name=default-value - Description.`

There are deliberately few parameters. Every new parameter is one more field in the form,
one more way to deploy the application wrong, and one more branch for you to maintain. A
good chart lets you configure what genuinely differs between installations, and nothing
beyond that.

### `values.schema.json` — what to consider valid

The schema is checked by Helm **before** anything travels to the cluster. Check it on the
spot: slip a string into a numeric parameter.

```bash
# template = "assemble the manifests from the chart and print them", the cluster is not touched:
#   gp                    the release name the chart is notionally deployed under
#   chart                 the folder with the chart
#   --set replicas=abc    override a single parameter right on the command line
helm template gp chart --set replicas=abc
```

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
guest-pass:
- at '/replicas': got string, want integer
```

The error is caught on the bastion in half a second. Without the schema it would have gone off
to the cluster and turned into a Deployment that never gets created, with a three-screen
message.

This same schema, word for word, will go into the `ApplicationDefinition` — and there it
grows into the creation form in the dashboard.

### `templates/configmap.yaml` — the page

```yaml
    <h1>{{ .Values.greeting }}</h1>
```

This is the whole reason a templating tool exists in the first place: a value from `values`
lands in the manifest at render time. Without Helm you would have to keep one copy of the
manifest per subsidiary and edit them by hand.

### `templates/deployment.yaml` — the application

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

The line everyone forgets, and that later costs an hour of debugging.

Kubernetes **does not restart Pods when a ConfigMap changes**. You edit the text, run an
update, the dashboard shows "updated," and the page still shows the old greeting. The
annotation with the config's hash changes together with the config, and a change to an
annotation in a Pod's template is already a change to the Pod itself, so the cluster
recreates it.

```yaml
            requests:
              cpu: {{ .Values.resources.cpu | quote }}
```

`quote` is mandatory here. Without quotes YAML reads the value `100m` as a string, but `1`
as a number, and in one case out of two you get a type error. Quotes remove this whole
class of problems at once.

### `templates/service.yaml` — the address

```yaml
  type: {{ if .Values.external }}LoadBalancer{{ else }}ClusterIP{{ end }}
```

A single boolean parameter decides whether the application gets an address outside the
cluster or not. This is exactly how the built-in Cozystack applications are made — most of
them have an `external` field with precisely this meaning. It is worth following others'
conventions in the catalog: someone who deployed three managed services before you will
look for this field in the same place and under the same name.

</details>

## Step 2. Verify the chart locally

📍 **Where:** on the bastion (in its terminal). No cluster is needed for this.

The linter first. It reads the chart as a set of files and catches structural errors: the
wrong indentation, a lost required field, a template that will not parse.

```bash
cd labs/13-catalog
# lint = "check the package for formatting errors and required fields"
#   chart   path to the chart folder; inside it Helm expects Chart.yaml, values.yaml
#           and the templates/ folder
helm lint chart
```

**What you should see:**

```
==> Linting chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

`[INFO]` is a remark, not an error: the chart has no `icon` field. For the Cozystack
catalog it is not needed anyway, the icon is taken from the `ApplicationDefinition`, which
we will get to.

Now the render. A template is a manifest in which some of the values are replaced by
substitutions of the form `{{ .Values.replicas }}`. Rendering is turning the templates into
finished manifests: Helm takes the values from `values.yaml`, substitutes them into the
text, and prints the result.

```bash
# main — the release name, that is, of this specific deployment of the chart. It goes
# into the names of the objects created, so two installations side by side will not clash.
helm template main chart
```

The output is ordinary manifests, the same ones you wrote by hand in the first labs. There
is nothing magical about Helm: it substitutes values into text.

Check that the parameters really reach the manifests. We render twice with different values
and keep only the line in the output that was supposed to change.

```bash
# --set replicas=5 overrides the value from values.yaml for the duration of one run.
# | grep 'replicas:' — from the whole output keep only the lines with this word.
helm template main chart --set replicas=5 | grep 'replicas:'
# the same for the boolean parameter: external decides which Service type ends up in the manifest
helm template main chart --set external=true | grep 'type:'
```

```
  replicas: 5
  type: LoadBalancer
          type: RuntimeDefault
```

The third line is not an error and not a typo of yours. `grep` searches for the word across
the entire text, and `type:` also appears in the security requirements (`seccompProfile`).
A useful reminder that `grep` does not understand YAML structure: it searches for lines,
not fields.

⚠️ **`helm template` sends nothing to the cluster and checks nothing on its side.** It
renders text. A manifest that passed `helm template` may still be rejected by the cluster —
for example, because of a missing CRD. It is a cheap check, not a complete one.

## Step 3. Break down the ApplicationDefinition

The chart knows how to deploy the application. But the catalog does not know about it yet:
for "Guest Pass" to appear as a listing in the dashboard and become a type of object in the
API, one more file is needed.

It lies right there — `applicationdefinition.yaml`.

<details>
<summary><b>A closer look: what's inside applicationdefinition.yaml</b></summary>

```yaml
apiVersion: cozystack.io/v1alpha1
kind: ApplicationDefinition
metadata:
  name: guest-pass
```

Notice what is **not** here: the `namespace` field. This is that very cluster-scoped nature
of the object. There is one per cluster, and the catalog entry it produces will be seen by
all tenants at once.

### The `application` block — how this looks in the API

```yaml
  application:
    kind: GuestPass
    plural: guestpasses
    singular: guestpass
```

After this file is applied, a new type of object appears in the cluster. Not an
"integration" and not a "plugin" — a full-fledged type you work with using ordinary
`kubectl`. These two commands will work for any tenant as soon as the admin applies the
definition:

```bash
# get = "show me what's there". guestpasses is that very name from the plural field below:
#   -n tenant-workshopXX   which namespace to look in; replace XX with your own number
kubectl get guestpasses -n tenant-workshopXX
# describe = "show me everything about one object": parameters, state, recent events.
# main here is the name of a specific ordered application, not the name of the type.
kubectl describe guestpass main -n tenant-workshopXX
```

`plural` is what gets substituted into commands and into the API URL. `singular` is what
you write in `kubectl describe`. Both are written in lowercase and without spaces — a
Kubernetes requirement, not a matter of style.

```yaml
    openAPISchema: |-
      {"title":"Chart Values","type":"object","properties":{...}}
```

The same schema that lies in the chart as the file `values.schema.json`, only written as a
single line of JSON. It works in two places: the API rejects invalid values, and the
dashboard draws the creation form from it — field types, default values, hints.

⚠️ **The schema here and the schema in the chart must match.** There is no automatic link
between them: these are two files, and keeping them in sync is your job. Let them drift
apart, and the form in the dashboard shows one set of fields while the chart expects
another. `check.sh` cross-checks them for you, but getting into the habit of that check is
worth it.

### The `release` block — what to deploy

```yaml
  release:
    prefix: guest-pass-
```

The release name is made of the prefix and the object's name: a `GuestPass` named `main`
deploys as the release `guest-pass-main`. The field is required. It is needed so that
releases of different applications do not clash names in one namespace: many things are
called `main`, but `guest-pass-main` is only yours.

```yaml
    labels:
      sharding.fluxcd.io/key: tenants
```

A Cozystack service label: by it, tenants' releases are distributed among Flux's handlers.
Without it there will be no one to service the release, and it will hang waiting. This is
not the place to show initiative — copy it as is.

```yaml
    chartRef:
      kind: HelmChart
      name: cozystack-guest-pass
      namespace: cozy-public
```

Where to get the chart from. There are three valid values of `kind`: `OCIRepository`,
`HelmChart`, `ExternalArtifact`.

External catalogs usually arrive via the chain `GitRepository` → `HelmChart`: the admin
adds your repository as a source in the `cozy-public` namespace, Flux pulls the chart out of
it, and the `ApplicationDefinition` references that chart. This is exactly the path shown in
`cozystack/external-apps-example`, and it is a sensible place to start.

⚠️ **The names in `chartRef` are not yours alone to invent.** They must match how the admin
registers the source. Agree on them before you send the file — otherwise the definition
will apply but there will be nothing to deploy, and the error will only surface for the
first person who clicks "create."

### The `dashboard` block — how this looks in the interface

```yaml
  dashboard:
    category: PaaS
    singular: Guest Pass
    plural: Guest Passes
    description: Internal guest pass service for employees and reception
    tags: [internal, web]
```

`category` is the catalog section. Cozystack uses five of them: `PaaS`, `IaaS`, `NaaS`,
`Administration`, `Networking`. Take an existing one. A section of your own means a section
of one entry, where no one will find your application.

`singular` and `plural` here are the **human** names, with spaces and capital letters. Do
not confuse them with the ones in the `application` block: those are for the API, these are
for the eye.

```yaml
    icon: PHN2ZyB3aWR0aD0iMTQ0IiBoZWlnaHQ9IjE0NCIgdmlld0JveD0iMCAwIDE0NCAxNDQi...
```

The icon is an SVG encoded in base64. Encoded, not a path and not a link: the dashboard does
not go anywhere to download it, the picture lives in the object itself.

The source is right there, in `icon.svg`, and the ready string is in `icon.b64`. If you
edited the source, the string has to be rebuilt. The encoder by default breaks the output
into lines, but the `icon` field needs one continuous string — so the line breaks are
stripped in a separate step.

```bash
# base64 = turn a binary file into a string of letters, digits and the signs + / =
#   -i icon.svg   what to encode (the flag spelling for macOS and BSD)
# tr -d '\n' = drop every line break from the output, gluing it into one
base64 -i icon.svg | tr -d '\n'
```

On Linux the same command has different flags: `base64 -w0 icon.svg`, where `-w0` means "do
not wrap the output at all." The GNU and BSD flag spellings do not match here.

The canvas size 144×144 matches the platform's built-in icons. More is not needed: in the
catalog it is drawn small.

```yaml
    keysOrder: [["apiVersion"], ["kind"], ["metadata"], ..., ["spec", "replicas"], ...]
```

The order of fields in the object's YAML representation. Cosmetic, but without it the fields
line up any which way — the rarely-used `resources` first, the main `replicas` after — and
the form reads worse than it could.

</details>

## Step 4. Try to apply — and get denied

📍 **Where:** on the bastion, with tenant access.

The file is ready and syntactically sound — let us try to apply it as though we had the
rights. The denial will come from the cluster, not from `kubectl`, and the text of the
denial will say exactly what was missing.

```bash
# tenant access — the same one you have worked with throughout the workshop
export KUBECONFIG=~/.kube/config
# apply = "bring the cluster into line with what's written in the file"; -f — read from a file
kubectl apply -f applicationdefinition.yaml
```

**What you will see:**

```
Error from server (Forbidden): error when creating "applicationdefinition.yaml":
applicationdefinitions.cozystack.io is forbidden: User "workshopXX" cannot create
resource "applicationdefinitions" in API group "cozystack.io" at the cluster scope
```

The denial is expected: it was stated at the start of the lab. What matters here are the
last four words — **at the cluster scope**.

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

Your rights in the tenant are rights inside a namespace. You are the full master of your
own piece: you spin up clusters, databases, VMs, delete them, break them, fix them. Not one
of your objects is visible to or interferes with a neighbor.

`ApplicationDefinition` is built differently. It changes the catalog **for all tenants at
once**. An application with an error in its schema, applied by you, will be seen and
attempted by people from other departments. An application named the same as an existing one
will break the existing one.

That is why the boundary runs right here, and it is not about mistrust. The same was true in
vSphere: you created your own VMs in your own pool yourself, but the contents of the shared
Content Library, and the rights to it — you did not.

**What to do in practice.** Hand the platform admin two files and one agreement:

| What to hand over | Why |
|---|---|
| `applicationdefinition.yaml` | the object itself, which he will apply |
| a link to the repository with the chart | from it the admin builds the source in `cozy-public` |
| the agreed names in `chartRef` | so the definition finds the chart |

And check before sending that both files are in order — because the feedback loop here is
long: the admin applies it, and a third person sees the error.

</details>

The denial could also have come from an error in the file itself. Let us separate the two:
first ask about permissions, then make `kubectl` parse the whole file, sending it nowhere.

```bash
# auth can-i = "am I allowed to?". The answer is yes or no, and the cluster is not changed.
kubectl auth can-i create applicationdefinitions
# --dry-run=client = "parse the file and show what would come out, but do not go to the cluster".
# client means the whole check runs on the bastion and the cluster never even hears about it.
kubectl apply -f applicationdefinition.yaml --dry-run=client
```

**What you should see.** The first command — `no`. The second —
`applicationdefinition.cozystack.io/guest-pass created (dry run)`: the file is parsed, the
syntax is fine, the issue really is permissions.

⚠️ **`--dry-run=client` checks only the syntax.** It asks the cluster nothing at all.
`--dry-run=server` would ask, but that requires those very rights that are missing.

## Step 5. What the subsidiaries will see

When the admin applies the definition, the catalog gains an entry. From that moment on any
tenant deploys "Guest Pass" the same way they deployed Redis: **Create application** →
`Guest Pass` → a form from your four parameters → a button.

Or as text — the file `guestpass-example.yaml` from this folder:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: GuestPass
metadata:
  name: main
  namespace: tenant-workshopXX
spec:
  replicas: 2
  greeting: "Order a pass for your guest"
  external: false
```

Notice the group: `apps.cozystack.io` — the same as for `Bucket` and `VMInstance`. Your
application has taken its place **in the same row** as the built-in ones, not off to one
side. It shows up the same way in the tenant's application list, its resources count the
same way, permissions work the same way.

⚠️ You cannot apply this file before the admin has registered the definition: `kubectl` will
answer `no matches for kind "GuestPass"` — there is no such object type in the cluster yet.

## Step 6. How not to write all of this by hand

Everything you took apart in this lab is a skeleton: `Chart.yaml`, `values.yaml`, the
schema, the templates, the `ApplicationDefinition` with the right names and labels. Half the
file is required fields that are the same everywhere, and it is easier to get them wrong than
to write them.

For this there is a ready-made tool.

| What | Where | Why |
|---|---|---|
| The `cozystack/ccp` repository | github.com/cozystack/ccp | a set of plugins and skills for Claude Code |
| The `cozystack` plugin | from there | teaches Claude Code the structure of Cozystack packages |
| The `external-app-create` skill | in the plugin | generates the entire external-application skeleton |
| The sample repository | github.com/cozystack/external-apps-example | a working example with building and publishing the chart |

The skill asks for the application name, the kind, the category, and the parameters — and
lays out a finished file tree: the chart with its schema, the `ApplicationDefinition` with
the right prefixes and labels, a Makefile for building.

Taking all of this apart by hand does not lose its point. The generated skeleton will still
have to be read and edited, and editing what you do not understand is the worst known way to
work.

## The check

📍 **Where:** on the bastion, in the same terminal window where you worked with `kubectl`.

The script runs **locally** and does not touch the cluster: it checks that the chart passes
the linter, that it renders, that the parameters really reach the manifests, that the
`ApplicationDefinition` parses and contains all the required fields, that the icon decodes
into SVG — and, most importantly, that the schema in the definition matches the schema in
the chart.

```bash
# ./ before the name means "the file from the current folder", that is, from labs/13-catalog
./check.sh
```

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to set it up is
written at the start of lab 0. Without WSL you can complete the lab, but there will be no
artifact report.

If `KUBECONFIG` is set, the script will also ask the cluster about permissions and confirm
that you are not entitled to apply the definition. The script counts the absence of rights
as the expected result, not as an error.

## Cleanup

There is nothing to clean up: you created nothing in the cluster. This is the only lab in
the workshop that leaves no trace, and that is its distinctive feature — the work of the
platform team mostly looks exactly like this: text, review, someone else's hands on the
apply.

Take the `chart/` and `applicationdefinition.yaml` files with you. This is a working
starting point; a real application for your catalog can grow out of it.

## What we can do now

- Package an application into a Helm chart with a parameter schema and verify it locally
- Write an `ApplicationDefinition` and explain the purpose of each of its blocks
- Understand why the catalog is shared and why a tenant has no rights to it
- Prepare the handoff to the admin so that he applies the file on the first try
- Know what to generate the skeleton with and which example to look at

## And in vSphere this would be

The Content Library and an OVF template with input fields. The mechanics are more alike than
they seem: one team prepares the template, another places it into the shared library, and
others deploy it.

The difference is in what you get out. An OVF template is a machine with a disk: you deploy
it, and from then on it lives on its own, and you will update it by hand on every copy. An
`ApplicationDefinition` is a description backed by a chart: update the chart, bump the
version, and all the installations update by one mechanism.

**Where vSphere is more convenient, honestly.** The Content Library is a ready-made
interface: drop in the file, hand out the rights, done. Here you need to set up a repository,
configure building and publishing the chart, agree names for the source with the admin — and
all of that before anything appears in the catalog. The barrier to entry is higher, and the
first application will take a day, not an hour.

It pays off on the second and third application, and especially on the first update.
Updating an application that has spread across five subsidiaries, from a chart, versus
updating the same application on five drifted-apart OVF copies — that is a different amount
of work. A different order of magnitude.
