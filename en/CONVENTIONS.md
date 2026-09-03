# How to write labs

Read this before your first edit to any lab. This document has a single goal: to make the
fifteen labs read as one piece of work, not as fifteen different ones.

## Who the reader is

A VMware system administrator. This is their first time seeing Kubernetes, or nearly the
first, and **that is fine** — the material is aimed at exactly this person. They are smart,
they have twenty years of experience, and they know virtualization, networking, and storage
inside out. What they do not know is our terminology.

Everything else follows from this.

## Rules of language

**No term without an explanation the first time it appears in this lab.** Not "it was
explained in another lab" — labs are done in no particular order. Explain it through
something the reader already knows from vSphere.

**Forbidden words:** "just," "obviously," "as usual," "merely," "trivially." If something
really is obvious, there is no need to write it. If it is not obvious, "just" demeans the
reader.

**Address the reader directly as "you."** No coyness, no false chumminess, no exclamation
marks.

**Don't sell.** No "powerful," "flexible," "solves every problem out of the box." The benefit
is shown through a fact and a comparison, not an adjective. Instead of "Cozystack delivers
high availability" — "delete a Pod and watch the clock."

**Be honest about the shortcomings.** If something works worse than it does in vSphere, say
so. The reader will notice anyway, and if we kept quiet, they will stop trusting the rest.

## The required structure of a lab

A `README.md` file in the lab's folder. The order of the sections is strict.

1. **Title** — `# Lab NN · Name`
2. **Header** — the time, what it proves, what you'll need
3. **Why this** — a task from real life, not "now we'll study X." A continuation of the
   running scenario (see below)
4. **Mini-glossary** — only the terms that are new to this lab, as a three-column table:
   term, what it is, "like… but." The third column names the thing from vSphere and, in the
   same breath, says how the term differs from it — in a single phrase, not two fragments in
   separate cells. There must be no separate "where the analogy breaks" column: out of
   context, its header means nothing
5. **What's in the lab's folder** — a table of every file in the lab: file, what it is, when
   it comes in handy. The reader should not have to guess where the `name.yaml` in an `apply`
   command came from, or whether they need to create it themselves. Every file the lab
   applies must live in its folder (or in a neighboring one, and then the path is written out
   explicitly: `../03-scale/hpa.yaml`)
6. **Steps** — one action per step
7. **Verification** — what the result should be and how to see it
8. **Cleanup** — mandatory, and with an explanation of why it's cheap
9. **What we can now do** — three or four points
10. **And in vSphere this would be** — an honest comparison, including where vSphere is more
    convenient

## The running scenario

All the labs are parts of one work task, not a set of exercises.

**The setup:** you are on the platform team. The business asks you to roll out an internal
service called "Passes" — an employee orders a pass for a guest through a mobile app,
security sees the list at the checkpoint, and management looks at a report once a month.

Each service appears **because of a specific pain**, not because its turn has come:

| What appears | Because of what |
|---|---|
| Harbor | security forbade pulling images from the internet |
| Redis | the employee directory in the legacy system takes 800 ms to answer |
| MongoDB | passes have different fields: one-time, weekly, for a car |
| OpenBao | an audit found the database password in a manifest |
| ClickHouse | management wants "how many guests, and when the peaks are" |
| Bucket | the mobile team has nowhere to put the APK |
| GitOps | there are three of us, someone changed something by hand and everything went down |
| Catalog | subsidiary companies want the same service for themselves |

Labs 0–4 are practice on a harmless application, before the real task begins. This is stated
outright: "training wheels first."

## Walking through code and manifests

**No YAML appears anywhere without a walkthrough.** Not a single file that the reader applies
without understanding it.

The walkthrough goes in a spoiler, so the main flow doesn't bloat:

```markdown
<details>
<summary><b>Walking through the manifest line by line</b></summary>

...line by line, in prose...

</details>
```

In the walkthrough we explain **why the block is needed**, not what is written in it. Bad:
"`replicas: 1` is the number of replicas." Good: "`replicas: 1` — how many copies to keep
running. If a copy disappears, the cluster creates a new one without asking. That's where
the self-healing in the next lab comes from."

## Predictable failures

**Every lab, where it fits, must include a check that will not pass.** The reader hits the
wall, diagnoses it, and comes to understand the need for the next step on their own.

The form is always the same, and its order is never rearranged:

1. We suggest checking, as if everything were already in place
2. **We show the error** — the output first, then the questions. Not the other way around
3. We stop the reader
4. A spoiler with the answer — and with a lesson broader than this particular error

Three places where the wording is fixed verbatim, so the labs don't drift apart.

The stop is always a block-quote callout, without ⚠️ (that marker is reserved for pitfalls):

```markdown
> **Stop and think before you read on.**
>
> A question. A second question, if there is one.
```

The spoiler's heading is always `The answer, and a lesson broader than this error`.

The paragraph with the lesson itself, inside the spoiler, opens like this:
`**The lesson is broader than this error.**`

The failure must be real, not staged. If a step works, there's no need to break it
artificially.

## Two paths: by mouse and by text

Where an action is available both in the dashboard and through `kubectl`, we show **both**
and say when each one is appropriate.

**Neither path is hidden in a spoiler.** Working by text is not a fallback for when the
dashboard is down: it is exactly what we are leading the reader toward, because a description
in a file can be reviewed, put into Git, and rolled back. The spoiler is for walking through
the fields, not for the way of working itself.

Managed services (Harbor, Redis, MongoDB, ClickHouse, OpenBao, buckets, virtual machines) —
we drive through the dashboard: that's where the feeling of self-service comes through.

Your own application — through `kubectl` and Git: that's where it comes through that
infrastructure is text, which can be reviewed and rolled back.

## Consistent naming

One thing is called the same in every lab and in every chat message. The reader goes through
the material in no particular order and should not have to guess that `lab` and "the lab
cluster" are one and the same.

| Thing | What we call it |
|---|---|
| The unit of material | "lab." Not "lab exercise," not "module," not "lesson" |
| The lab cluster from lab 0 | the `lab` application |
| The practice application of labs 0–4 | `rickroll` |
| The production service of labs 5–14 | "Passes" in the text, `passes` in the manifests |
| The tenant number | `workshopXX` in placeholders, `workshop03` in worked examples |

Separately: **the paths to the access files and the names of the environment variables are
the same everywhere.** If in one lab the tenant kubeconfig lives at one path and in a
neighboring one at another, the reader will decide these are two different files and end up
keeping two of them.

A lab's name in its title and its short name in the root `README.md` table must be
recognizable in each other. "Cache" in the table and "A cache in front of a slow backend" in
the file are clearly the same lab. If the table says one word and the title says another, the
reader will open files at random.

The time in the lab's header and the time in the root `README.md` table are the same number.
In the header we give the full time, including waiting, and separately note how much of it is
spent waiting.

## Formatting

- Sections and steps are both `##` level. A step's heading: `## Step N. What we do`. We do
  not use the words "part," "stage," "exercise" — everywhere it's "step." Subheadings within
  a step are `###`, but more often a spoiler is the better fit
- Commands go in blocks with the language marked: ` ```bash `, ` ```yaml `, ` ```sql `
- Before each command, what is about to happen. After it, what you should see
- Lines no longer than 100 characters
- Emoji are functional markers only: 📍 where it runs, ⚠️ a pitfall. Nothing more in the labs.
  In chat messages, these are joined by 🖱 the mouse path, 📄 a file from the repository,
  ⏳ a long wait — and that closes the list
- Tables instead of lists wherever there are columns

## Verification

In every folder there is a `check.sh`. The participant runs it themselves and gets a report:
what was checked, what passed, what didn't, and the evidence attached. The requirements for
the scripts are in `check/README.md`.

In the lab's text we reference it in the "Verification" section.

## What not to do

- Don't reference step numbers from other labs — they are done in no particular order
- Don't reference a step number even inside your own lab ("the predictable failure in
  step 7"): steps shift when you edit, and the reference quietly becomes misleading. Write "a
  little further along in the lab"
- Don't assume the previous lab has been done unless it's written under "what you'll need"
- Don't leave `TODO`, `TBD`, or placeholders in the published text
- Don't invent manifest fields or Secret names. Check them against
  `packages/apps/<app>/values.schema.json` in the cozystack repository
