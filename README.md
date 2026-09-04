# Cozystack Migration Workshop

A hands-on workshop for people who administer **VMware vSphere** and want to
understand **Cozystack** — not from slides, but with their hands on a real
cluster. Kubernetes knowledge is not required: everything is explained along the
way, through what you already know from vSphere.

This repository holds the workshop in **several languages**. The content is the
same everywhere; only the prose is translated. Commands, manifests, scripts and
technical terms are identical across languages.

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

## What gets translated, and what does not

Translated: prose only — every `README.md`, the `chat/*.md` messages,
`CONVENTIONS.md`, `REQUIREMENTS.md`, and the human-language **comments inside
code blocks** (a `# …` in a bash block is teaching, so it is translated).

Never translated: commands, code, YAML manifests, file and directory names,
command output, the demo apps' data and UI strings, and the technical terms
fixed in [`GLOSSARY.md`](GLOSSARY.md). A lab must run identically in every
language — the executable content of every code block is byte-identical across
languages.

The shipped assets under `scripts/`, `manifests/` and each lab's `check.sh`
are the Russian originals in every language tree (their in-file comments and
`check.sh` on-screen output are not yet localized); the labs run the same in
all languages, and the prose that surrounds them is fully translated.

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
2. Re-generate or hand-carry the change into `en/`, then into `zh/` and `es/`.
3. Keep terminology in line with [`GLOSSARY.md`](GLOSSARY.md) and the voice in
   [`STYLE.md`](STYLE.md).
4. Never let the code diverge between languages — if you change a manifest or a
   script, copy it verbatim into every language.
