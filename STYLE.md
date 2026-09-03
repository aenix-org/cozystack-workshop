# Translation style guide

The workshop is written in a particular voice, and the translations must keep
it. A correct-but-wooden translation is a failed translation here.

## Voice

- **Teach through vSphere.** Every new idea is anchored to something the reader
  already knows from vSphere — and then the guide says where the analogy breaks.
  Keep both halves: the analogy *and* the caveat.
- **No jargon dumps.** Terms are introduced in plain words before they are used.
  Do not "upgrade" the register or add jargon the source does not use.
- **Warm and precise.** The tone is a knowledgeable colleague, not a manual and
  not a marketer. Short, concrete sentences. No filler, no hype.
- **Second person, addressing the reader** ("you") — as the source does.

## Literary quality, not literal calque

- Translate **meaning and rhythm**, not word for word. The result must read as
  if it were written in the target language by an engineer who writes well.
- **No unnecessary anglicisms.** In Chinese and Spanish especially, do not
  transliterate an English word when a natural, established term exists. Keep in
  English only what `GLOSSARY.md` says to keep (product names, CLI names,
  Kubernetes object names).
- Keep the source's **information exactly** — do not summarize, expand,
  soften, or add examples. Same facts, same warnings, same order.

## Formatting — preserve exactly

- Never translate anything **inside code fences** (``` ``` ```), inline code
  (`` `like this` ``), command output, YAML, file paths, or URLs.
- Preserve all Markdown structure: headings and their levels, tables, lists,
  block quotes, `<details>`/`<summary>`, links, and image references.
- Keep the callout markers verbatim: `📍`, `⚠️`, and the bold lead-ins like
  `**Где:**` → translate the label text but keep the marker and the bolding.
- Comments **inside** code blocks (e.g. `# ...` in a bash block) *are* prose and
  **should** be translated — but the code around them must stay byte-identical.

## Terminology

- Follow `GLOSSARY.md` for every listed term, in every language.
- Be consistent within and across files: the same source term always maps to the
  same target term.
- The tenant placeholder `workshopXX`, `~/.kube/config`, `~/lab.kubeconfig`, and
  every file name stay verbatim.

## Definition of done for a language

Every prose file translated; no leftover source-language sentences; glossary
respected; code, YAML and output byte-identical to the source; it reads
naturally to a native-speaker engineer; and five independent reviewers have
signed off on accuracy, terminology, fluency, and absence of anglicisms.
