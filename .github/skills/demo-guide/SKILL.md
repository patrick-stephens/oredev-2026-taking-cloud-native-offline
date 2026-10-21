---
name: demo-guide
description: 'Answer questions about the cloud-native offline demos, how they work, what their tools do, and which demo to choose. Use for demo walkthroughs, architecture explanations, tool comparisons, prerequisites, connected versus air-gapped phases, and troubleshooting.'
---

# Demo guide

Help people understand this repository using its current documentation and
implementation. Keep answers concise and accessible; explain unfamiliar terms.

## Find the relevant demo

1. Start with the [demo index](../../../README.md) to map a demo ID, name, tool,
   or topic to its directory. Use this index rather than maintaining a separate
   inventory in this skill.
2. Read the selected demo's README under [live-demos](../../../live-demos) or
   [advanced-demos](../../../advanced-demos). For a broad discovery question,
   suggest a few relevant demos and explain why. If the intended demo is still
   ambiguous, ask a focused clarification.
3. Read its `PRESENTATION_NOTES.md`, when present, for talk flow and intended
   teaching points.
4. For implementation details, follow the README into the demo's scripts and
   configuration. Inspect the actual entry point and helpers, plus relevant
   manifests, charts, or application files. Do not assume every demo has the
   same script names or layout.

## Explain from evidence

Tailor the answer to the question rather than always giving a full walkthrough:

- **Overview or walkthrough:** explain the purpose, architecture, key steps,
  expected result, and what the demo proves.
- **Tool question:** explain what the tool does, its specific role here, how it
  interacts with the other components, and which scripts/configuration use it.
  Distinguish general tool capabilities from what this demo actually exercises.
- **Running a demo:** use its documented prerequisites, pinned versions, commands,
  verification steps, and cleanup. Check [tested versions](../../../docs/tested-versions.md)
  when discussing compatibility; do not invent commands or claim newer versions
  have been tested.
- **Offline behavior:** separate connected preparation, artifact transfer, and
  disconnected execution. Identify what is cached, bundled, mirrored, or trusted,
  and any remaining network requirements. Distinguish simulated isolation from
  a genuinely air-gapped deployment.
- **Comparison:** read each relevant demo's documentation before comparing
  goals, tools, trade-offs, and offline boundaries.
- **Troubleshooting:** consult the demo's troubleshooting section and relevant
  scripts/configuration. Distinguish documented expectations from observed
  results, and request logs or environment details when needed.

Cite the repository files supporting the answer, with line references when
available. If documentation and implementation disagree, point out the mismatch
and explain what the code does. State when an answer is not established by the
repository rather than guessing.

## Keep queries read-only

An explanation request is not permission to run a demo. Do not start containers
or clusters, install tools, download artifacts, change network settings, or run
cleanup just to answer a question. Show relevant commands as examples and make
their working directory and side effects clear. Never claim a demo was executed
or verified unless it actually was.
