# Cozystack Migration Workshop

A hands-on workshop for people who administer **VMware vSphere** and want to
understand **Cozystack** — not from slides, but with their hands on a real
cluster. Kubernetes knowledge is not required: everything is explained along the
way, through what you already know from vSphere.

This repository holds the workshop in **several languages**. Every language is a
fully localized experience — the prose, the on-screen output, and the demo
applications' data and interface all read natively — while the executable content
(commands, manifests, code) stays byte-identical, so a lab runs the same in every
language.

## Languages

| Directory | Language | Status |
|-----------|----------|--------|
| [`ru/`](ru/) | Russian — the authored source of truth | complete |
| [`en/`](en/) | English — flagship translation, and the pivot for the others | complete |
| [`zh/`](zh/) | Chinese (Simplified) | complete |
| [`es/`](es/) | Spanish | complete |
| [`ja/`](ja/) | Japanese | complete |
| [`ko/`](ko/) | Korean | complete |
| [`de/`](de/) | German | complete |
| [`hi/`](hi/) | Hindi | complete |

Russian is where the text is written and edited first. English is translated
from Russian and polished to flagship quality; the other languages are produced
from English (a cleaner pivot for machine translation) and reviewed by native
speakers. See [`STYLE.md`](STYLE.md) for the translation rules and
[`GLOSSARY.md`](GLOSSARY.md) for the canonical terminology.

## What is inside each language

Every language directory is a complete, self-contained copy of the workshop with
two ways to take it — pick the one your host tells you:

| | `laptop/` — from your own laptop | `bastion/` — through a shared VM |
|---|---|---|
| **Tools** | you install them: `kubectl`, `virtctl`, `kubelogin` | already installed on the VM |
| **Cluster access** | kubeconfig from the dashboard, browser login | you SSH in, access is already set up |
| **Tenant number in files** | you substitute it yourself | pre-substituted on the VM |
| **Checking the app** | `virtctl port-forward` + `localhost:8080` | by the platform domain name |

Inside each of `laptop/` and `bastion/`:

- `README.md` — the route through the path
- `labs/00-cluster` … `labs/15-monday` — the sixteen labs, each with its own
  `README.md`, manifests, and a `check.sh` that verifies the lab worked
- `chat/` — the step-by-step messages the host posts during a live session
- `manifests/`, `scripts/` — files applied to or run inside the cluster
- `check/` — the shared library the per-lab `check.sh` scripts build on

At the root of each language:

- `README.md` — how to choose your path
- `CONVENTIONS.md` — writing and structure conventions for the labs
- `REQUIREMENTS.md` — what a venue needs to run the workshop
- `demo/` — a small demo the host can run

## What is localized, and what stays identical

Localized into every language: all prose (each `README.md`, the `chat/*.md`
messages, `CONVENTIONS.md`, `REQUIREMENTS.md`), the human-language **comments**
inside the shipped manifests, scripts and code, the **on-screen output** of each
`check.sh`, and the **demo applications' content** — the guest-pass sample data,
the text the apps print and render, and the reader-facing interface. Each
language uses one canonical demo dataset (native names, departments, entrances,
pass types), so a lab's seed data, its queries, its `check.sh` and the
surrounding prose all agree.

Kept byte-identical across every language, so a lab runs the same everywhere:
commands, code, YAML keys and identifiers, control flow, file and directory
names, format specifiers, exit codes, the strings a `check.sh` matches against
program output, and the functional fill-in placeholders. The executable content
of every code block is identical across languages, and the technical terms fixed
in [`GLOSSARY.md`](GLOSSARY.md) are kept verbatim.

Real-world markers are deliberately neutral: the sample scenario carries no
country-specific car plates, vehicle brands or email domains — each is rendered
in a form natural to the language (or a neutral one), including in the Russian
source.

## How the translations were made

Russian is authored first. English is translated from Russian and polished to
flagship quality; Chinese and Spanish are translated from the English pivot.
Every language's prose was then reviewed by **five independent reviewers**, each
on a different lens — technical accuracy, terminology against
[`GLOSSARY.md`](GLOSSARY.md), literary fluency, absence of anglicisms, and
structural integrity (code/output byte-identity, Markdown parity) — and every
finding was applied before the language was committed.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [`NOTICE`](NOTICE).

## Contributing a fix or a translation

1. Edit the **Russian** source under `ru/` (that is where meaning is decided).
2. Re-generate or hand-carry the change into `en/` (the pivot), then into the
   other language trees.
3. Keep terminology in line with [`GLOSSARY.md`](GLOSSARY.md) and the voice in
   [`STYLE.md`](STYLE.md).
4. Never let the executable content diverge between languages — if you change a
   manifest or a script's code, copy it verbatim into every language; only prose,
   comments, on-screen output and demo content are localized per language.
