# Future tooling map

The projects below represent upcoming ecosystem work and the demos that provide concrete examples of it.

## OCI 1.1 artifacts and referrers → ADV-03

OCI artifacts and referrers are making registries useful for more than container images: SBOMs, policies, signatures, and models can be attached as discoverable artifacts. ADV-03 demonstrates keeping that artifact graph intact as it moves offline.

## Policy verification → ADV-04

Admission and verification tooling is shifting trust decisions closer to deployment, instead of relying on a registry being reachable at runtime. ADV-04 demonstrates locally bundled trust roots and verification inside the boundary.

## P2P distribution → ADV-02 and ADV-11

Peer-to-peer distribution can reduce repeated downloads and make large fleets less dependent on a single central registry. ADV-02 explores node-to-node image retrieval, while ADV-11 pairs an enterprise registry with preheating for broad distribution.

## Purpose-built air-gap packaging → ADV-01

Packaging tools are converging on repeatable bundles that can carry images, charts, Git content, and supply-chain metadata together. ADV-01 uses that model to move a self-contained package into a disconnected cluster.

## Lightweight clusters → ADV-06 and ADV-12

Smaller cluster distributions and lifecycle tools are lowering the operational cost of running Kubernetes at the edge and in disconnected sites. ADV-06 focuses on a lightweight k3s install; ADV-12 demonstrates an offline install and upgrade workflow.

## Minimal images → ADV-10 and ADV-08

Minimal image construction reduces attack surface and can make it easier to reason about the packages needed at build and runtime. ADV-10 builds with local APK packages, while ADV-08 applies the same dependency discipline across language and OS package ecosystems.

## GitOps offline → ADV-07

GitOps tooling is expanding beyond cloud-hosted control planes to support reconciliation inside the same restricted boundary as the workloads. ADV-07 demonstrates the full push, reconcile, and deploy loop using local Git services and bundles.
