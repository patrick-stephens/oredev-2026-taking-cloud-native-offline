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

## CI validation

The `Lint` workflow runs each linter as a separate job on pull requests and pushes to `main`, plus a `pre-commit` job for the remaining hygiene, secret-scanning, spelling, schema, and workflow-security hooks. GitHub Actions references must be pinned to full commit SHAs: use `pinact run` to pin them; CI and zizmor enforce this. Workflows are linted with the actively maintained [kjanat/actionlint](https://github.com/kjanat/actionlint) fork of actionlint (both the CI action and the pre-commit hook), which also supports GitHub's `$/` self-repository reusable-workflow syntax.

Run the same checks locally before committing with [pre-commit](https://pre-commit.com/):

```bash
python3 -m pip install --user pre-commit
pre-commit install
pre-commit run --all-files
```

All hooks come from their upstream projects, and revisions in `.pre-commit-config.yaml` are frozen to commit SHAs; refresh them with `pre-commit autoupdate --freeze` and check that each frozen tag matches the project's latest release. Dependabot proposes weekly grouped updates for both GitHub Actions and pre-commit hooks after a 7-day cooldown. Tool versions installed directly in `lint.yaml` (yamllint, Ruff, Hadolint, Go, Helm, pinact, and pre-commit) are not managed by Dependabot; keep them aligned with `.pre-commit-config.yaml` manually.

`shfmt` and JSON auto-formatting are intentionally not enabled: they would rewrite most existing shell scripts and committed configuration/SBOM files without fixing defects.

The reusable `Demo run-through` workflow provisions and runs one demo on a dedicated self-hosted runner labeled `offline-demo`. The runner must be Ubuntu x86_64 with rootful Docker Engine, Compose v2, Buildx, sufficient disk/memory, and non-interactive sudo. It runs repository code with host privileges, so do not expose the runner to fork pull requests. Manual runs can select a demo; select the PR branch in the Actions branch selector to test its changes. `Demo matrix` runs the supported demos sequentially. ADV-12 is omitted because it requires an external Kubean management cluster and additional virtualization setup.
