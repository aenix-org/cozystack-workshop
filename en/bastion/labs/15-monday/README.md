# Lab 15 · What to do on Monday

| | |
|---|---|
| **Time** | 20 minutes, and not a single command |
| **What it proves** | What you've learned can be applied to your own fleet, starting small |
| **What you'll need** | Just you and a list of your systems |

There are no commands here, and no `check.sh`: only Monday can check this lab.
A conversation about what to do next, once the testbed is switched off and everything at work is just as it was.

## What we ended up with

Over fourteen labs you've built a working internal service — "Pass," through which an
employee requests a pass for a guest, security sees the list at the checkpoint, and management
looks at a report once a month. Each part appeared not in sequence, but out of a specific pain:

| What appeared | Why |
|---|---|
| Your own image registry | The security team forbade pulling images from the internet |
| A cache | the legacy employee directory took 800 ms to respond |
| Document storage | passes have different fields: single-use, weekly, vehicle, group |
| Secret storage | an audit found the database password in a manifest |
| An analytics database | management wanted to know how many guests there are and when the peaks are |
| A bucket | the mobile team had nowhere to put the APKs they built |
| Infrastructure in Git | there are three of you, someone made a change by hand — and everything went down |
| Your own entry in the catalog | subsidiaries wanted the same service for themselves |

You didn't install or update a single one of these services: they're catalog entries that the
platform is responsible for. The only thing you installed and fixed was your own application.

Next — about how to repeat this off the testbed.

## Why this matters

The most common fate of training like this is "interesting, but it won't work for us." Not because
it won't, but because after fourteen labs it's unclear where to start in your own infrastructure,
where there are three hundred VMs and no one remembers what half of them do.

Let's work through it in order: where to start, what not to touch, and how to explain the point to
the people who sign off on the budget.

## Where to start: three candidates for the first move

Not with the most important application. And not with the most neglected one. You start with the
one where a mistake is cheap and the result is visible.

### Candidate one: the thing you were going to reinstall anyway

Everyone has a system about which it was long ago decided "we really should move it to a new OS" or
"it's time to update the version." That's the ideal first move: you were going to touch it anyway,
so the risk is already built into the plan, and you need exactly the same number of approvals.

### Candidate two: a test or demo environment

A copy of the production application that you won't miss. Here you'll test your own ability to repeat
the migration, not the platform — the platform you already tested at the workshop. The difference is
that now it's your images, your networks, and your security policies.

### Candidate three: the thing that's asking for new resources

A team that's come for a couple of VMs for a new service is the most convenient case. Nothing is
being migrated, everything is created from scratch, and you show them a dashboard right away instead
of a request form. Both sides will see the difference in speed.

## What not to touch first

**A system with a license tied to hardware.** Check the terms before you move anything. There are
products that count licenses by the hypervisor's physical cores, and the move can end up costing more
than it saves.

**Anything you don't understand.** If a contractor installed the application seven years ago and no
one has been inside it since, the migration turns into an investigation. It's doable work, but not
the first job.

**Clustered systems with their own fault tolerance.** Databases with replication, application
clusters, anything that keeps an eye on its own copies. Here you have to decide who's now responsible
for fault tolerance — the application or the platform — and that's a separate conversation with the
system's owner.

## An order that works

1. **Stand up a testbed.** Not for a migration — so you have somewhere to check any hunch within the
   same hour, without filing a request. One server, one install, zero commitments.
2. **Move one system from those above.** In full, with its data, to the point of "it works and users
   are looking at it."
3. **Live with it for a month.** Here you'll learn what no workshop can give you: how it behaves at
   three in the morning, what breaks during an update, what's missing from the monitoring.
4. **Only now build a plan for the rest.** With numbers obtained on your own hardware, not from a
   presentation.

Between steps 2 and 3 you'll usually want to speed up. Don't: a month of running one system in
production teaches you more than ten systems moved in the same week.

## How to explain this to management

The conversation won't be about technology. Three things usually decide it.

**License cost** — the most common argument, but also the most slippery. Count honestly: the savings
include not just the line you cross out, but also the cost of your time on the move, training the
team, and the period when both platforms are running at once.

**Speed of provisioning resources.** Here you have first-hand experience: with your own hands you
brought up a cluster in ten minutes and a database in five. Compare that with how long the same
request takes at your company. That's a number the business understands without translation.

**Independence from a single vendor.** An argument that has grown weightier in recent years. It works
not on its own, but in tandem with the first: the ability to switch platforms is exactly what gives
you a negotiating position on price.

What's better not to promise: that it will be simpler. It won't be — at least not the first year.
It'll be cheaper, faster at provisioning resources, and free of lock-in to a single vendor, but it
won't be simpler. Promising simplicity is the fastest way to lose trust six months later.

## Where to go with questions

- **The community on Telegram** — the same chat the workshop ran in. The question "how do I do this
  properly" is always welcome.
- **Documentation** — [cozystack.io/docs](https://cozystack.io/docs/).
- **Source code** — [github.com/cozystack/cozystack](https://github.com/cozystack/cozystack).
  If something behaves differently from what's written, it's usually faster to look in the chart than
  to guess. You've already done this in the lab about your own registry.

## What we can do now

- Choose the first system to move by the criterion "cheap to get wrong," not "most important"
- Tell the cases worth deferring from the ones worth taking on now
- Not promise management a simplicity that won't be there
- Know where to ask when no one nearby knows the answer

## And in vSphere this would be

The conversation would be shorter: you already know what to do on Monday, because you've been doing
it for ten years. That's the difference — not in the technology, but in the fact that here you'll
have to build your habits again from scratch.

The good news is that you can build them up gradually, one system at a time. The bad news is that for
the first few months you'll work more slowly than you're used to. Speed comes back as the new habits
accumulate — but you'll have to factor that lag into your timelines in advance.
