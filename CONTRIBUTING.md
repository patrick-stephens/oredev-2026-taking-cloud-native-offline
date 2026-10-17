# Contributing

Each demo is an independent, repeatable exercise. Keep its setup, helpers, artifacts, and instructions within its own directory.

## Connected and air-gapped phases

Every demo must explicitly separate two phases:

1. **CONNECTED** — fetch, build, scan, sign, or package everything the demo needs.
2. **AIR-GAPPED** — run the workload using only what crossed the documented transfer boundary.

Any network access during AIR-GAPPED is a bug. Make isolation observable; for example, use `docker network create --internal`, a default-deny NetworkPolicy, iptables inside the node, or stop the upstream service.

## Demo conventions

- Provide one terminal experience through `scripts/run-demo.sh`, with clear phase banners, and a separate `scripts/cleanup.sh`.
- Make scripts idempotent, start shell scripts with `set -euo pipefail`, and pin tool versions.
- Include a **Tested with** section and test date in each demo README.
- Use this required README section order:
  1. Purpose
  2. Spectrum level (link to [`docs/offline-spectrum.md`](docs/offline-spectrum.md))
  3. Architecture (ASCII or Mermaid)
  4. Prerequisites
  5. Quick start
  6. Step-by-step with expected output
  7. Troubleshooting
  8. Where network is still required
  9. Future tooling
  10. Cleanup
  11. Tested with
- Never commit keys, certificates, tokens, or generated bundles. Add matching `.gitignore` entries for demo-specific generated files. Do not ignore public cosign `.pub` files or trust-store certificates that a demo intentionally ships.
- Keep every demo self-contained. Duplicate helpers rather than cross-importing between demos.
- Be honest about validation: mark steps that could not be tested as `# UNTESTED` in code and list them under **Known limitations** in the README. Never fake output.
- Do not add a LICENSE file; the repository owner licenses at the repository level.

## Assembly mapping

The live-demo companion agents deliver their work in local `demo-cache/` and `demo-bundle/` folders. During assembly, map them as follows; the destination paths are canonical:

| Companion folder | Canonical destination |
|------------------|-----------------------|
| `demo-cache/` | `live-demos/1-pull-through-cache-zot/` |
| `demo-bundle/` | `live-demos/2-offline-bundle-cosign/` |

## Versions and assumptions

Append tested tool versions to [`docs/tested-versions.md`](docs/tested-versions.md) and to the relevant demo README. Record external dependencies and their offline strategies in the demo's assumption matrix.
