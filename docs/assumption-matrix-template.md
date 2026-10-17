# Assumption matrix template

Copy this table into a demo directory and replace the examples with the dependencies and transfer assumptions for that demo.

| Dependency | Category | Where used | Required? (hard/soft) | Offline strategy (cache / mirror / bundle / must-configure) | Transfer mechanism (bundle / media / preheat) | Owner | Notes |
|------------|----------|------------|-----------------------|-------------------------------------------------------------|-----------------------------------------------|-------|-------|
| `docker.io/library/alpine:3.20` base image | image registry | Builder image for the example workload | Hard | Bundle the pinned image and load it into the local registry before AIR-GAPPED | Bundle | Demo maintainer | Pin by digest as well as tag; verify the image is available without DNS or egress |
| `https://charts.jetstack.io` (`cert-manager` chart) | chart/artifact repository | CONNECTED phase Helm chart fetch | Hard | Mirror the pinned chart and dependencies into the local OCI registry | Bundle | Demo maintainer | Record chart version and chart digest; no repository lookup during AIR-GAPPED |
| `otlp.nr-data.net:4317` | telemetry/observability endpoint | Application OTLP exporter | Soft | Must-configure: point the exporter at a bundled local collector, or disable telemetry before transfer | Bundle | Platform operator | Pre-stage the collector image and configuration; the demo must still work if the external endpoint is unreachable |

## Category legend

- image registry
- chart/artifact repository
- OS packages
- language dependencies
- telemetry/observability endpoint
- DNS
- NTP
- certificate authority
- external API
- vulnerability database
- Git provider

## How to fill this in semi-automatically

- Grep the demo sources and rendered manifests for hardcoded registry references.
- Use SBOM tooling such as [Syft](https://github.com/anchore/syft) to enumerate image dependencies.
- Review Helm values for external endpoints, including telemetry, APIs, DNS, and certificate settings.

Treat automated results as an inventory to review, not proof that every assumption has been found.
