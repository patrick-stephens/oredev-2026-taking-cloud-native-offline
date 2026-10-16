# Presentation notes: offline vulnerability scanning

## Story

Start with a familiar failure mode: vulnerability scanners look self-contained,
but their decisions depend on an external, continuously refreshed database.
Taking only the scanner binary into a restricted site gives you a scanner with
no useful current knowledge. This demo transports the scanner, its database,
and an image together, then proves the scan can proceed without external
egress—and that a forced refresh cannot.

## Key beats

1. **Connected preparation:** call out the DB dates/schema, exact scanner
   versions, and the selected legacy image tag. The candidate selection requires
   positive findings from *both* scanners; it exits rather than faking a result.
2. **Transport boundary:** show the single archive contains binaries, database
   caches, and the OCI layout. Discuss why the scan target and DB have to travel
   together.
3. **Air-gapped transition:** emphasize Docker's `--internal` network and that
   the registry and scanner containers share only that network. The imported
   registry is reachable; public update endpoints are not.
4. **Offline scan:** compare Trivy and Grype's finding counts and explain the
   meaning of a database's build/published timestamp.
5. **Negative proof:** show both forced online update attempts return errors.
   A successful scan alone would not prove the environment had no internet.
6. **Close:** ask how often the organization can re-bundle the DB and how
   freshness is enforced. Relate this to Ratify's admission policy concept:
   vulnerability evaluation needs trustworthy, fresh inputs too.

## Likely questions

- **How often do you re-bundle the DB?** At least within the scanner's supported
  freshness window; Grype's default DB age validation rejects data more than
  five days old. Pick a cadence with margin for approval and transport delays,
  and alert on bundle age rather than silently disabling the check.
- **What if the transport takes longer than the DB's valid age?** Refresh and
  re-sign/re-attest the bundle before importing it. Preserve the generation
  timestamp and source metadata so the offline site can enforce its own policy.
- **Does `--internal` prove the host has no internet?** No. It proves egress is
  blocked for containers attached only to that Docker network. It doesn't
  firewall the host, prevent privileged escape, or cover another network
  attachment.
- **Why include an internal registry?** The requirement is to scan an imported
  image without pulling it from a public registry. Registry scanning is a
  realistic target in disconnected clusters. An OCI-directory scan is a useful
  alternative when no local registry is needed.
- **Why can the tools disagree on CVE counts?** They normalize packages and
  vulnerability sources differently. Counts are evidence that each scanner
  found issues, not a direct accuracy or severity comparison.
- **What is the relationship to Ratify?** Ratify applies policy to image
  signatures and attestations at admission. This demo focuses on the adjacent
  operational requirement that the vulnerability database used by a policy
  scanner is present and fresh.
- **Could this be a Kubernetes CronJob?** Yes, with a DB bundle mounted
  read-only, a controlled registry endpoint, and default-deny egress. The
  cluster stretch is intentionally not part of this smallest reproducible demo.

## Presenter setup

Run `DEMO_AUTO_ADVANCE=1 ./scripts/run-demo.sh` once before the talk to pre-pull
and verify every dependency. For the live run, omit `DEMO_AUTO_ADVANCE` so the
script pauses between connected preparation and the air-gapped scan. Make sure
the connected database download and image pull are recent enough for Grype's
five-day DB freshness check.
