# Presentation: Zarf package lifecycle

## Story

The basic bundle demo shows the plumbing. Here the unit of delivery becomes a
declarative package: image, chart, Git, file and SBOM. The important transition
is not the tarball; it is bootstrapping delivery services **after** egress is cut.
Zarf is an OpenSSF project contributed by Defense Unicorns in June 2024.

## Key beats (one terminal)

1. Start `./scripts/run-demo.sh`. Explain CONNECTED versus AIR-GAPPED before
   reading logs. The tools and matching init archive are infrastructure assets.
2. Show `zarf-config.yaml`. Three external sources, one package; no `image.registry`
   override. The Git ref is a commit, not a mutable branch.
3. Show the built-in SBOM count. Inventory is not vulnerability assessment.
4. At isolation, point out the deliberate external HTTP failure. All subsequent
   CLI commands run inside the blocked node; an online host cannot mask misses.
5. Explain the injector chicken-and-egg problem while init runs: ConfigMaps,
   cached infrastructure image, temporary seed registry, permanent registry.
6. Show `before-describe.txt` versus `after-describe.txt`. Inspect **the pod**:
   the Deployment template can still reference GHCR. Admission mutation changes
   the actual pull source to localhost and supplies credentials.
7. Show package list, local registry entry and the mirrored Git commit. This is
   source delivery, not an installed GitOps reconciler.
8. End on the zero forbidden-traffic counters, offline SBOM extraction and final
   blocked request from the running pod. Leave the cluster isolated for questions.
9. Run `./scripts/cleanup.sh` when finished.

Allow around three minutes with assets staged; reserve more for narration.
Scripts clear between phases and sleep one second, but never fabricate success.

## Likely questions

- **Does the package include Kubernetes?** Not this application package. The
  connected phase pre-provisions k3d, k3s and the StorageClass helper. The matching
  init archive includes delivery-service images, charts and injector.
- **How is no egress proven?** Pre-filter mangle OUTPUT/FORWARD hooks block
  IPv4/IPv6 external traffic. Node and pod negative controls fail; counters
  remain zero during lifecycle operations. Local cluster traffic is allowed.
- **Why no NetworkPolicy alone?** Host-network processes, containerd and the
  Zarf CLI are also dependencies; pod-only policy would miss them.
- **Why does the Deployment still say GHCR?** The agent mutates admitted pods.
- **Is this signed?** The optional signing stretch is not implemented. Do not
  imply an SBOM or release checksum authenticates a publisher.
- **What about unrelated host storage?** Demo-only absolute disk thresholds
  avoid percentage-based pressure; we never prune other projects.
- **Can Git be optional?** Yes, but this package explicitly requires it and init
  installs local Gitea. Removing it would change this demonstration's scope.
- **Is it production-ready?** No. Single node, disposable storage, trusted
  administrators; identity, revocation, updates, capacity and recovery need policy.

## Rehearsal and failure plan

Pre-stage using the CONNECTED script, then clean up and run the full orchestrator
to verify the cold-cluster path. Test on the presentation machine. Keep `.state/`
private: generated init logs can contain credentials. If offline deployment
fails, show the actual diagnostic and explain the missing dependency; never
restore internet mid-demo or loosen the firewall to produce a green screen.
