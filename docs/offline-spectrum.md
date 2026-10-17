# Offline spectrum

The spectrum describes the strength of the network restriction a demo can tolerate. A higher level has fewer external dependencies and requires more of the supply chain to be available inside the boundary.

| Level | Restriction | Typical needs | Example environments |
|-------|-------------|---------------|----------------------|
| 1 | Internet is present but metered or monitored | Pull-through caches and mirrors | Constrained bandwidth, regulated egress |
| 2 | Egress allowlist only | Private registries, internal mirrors, and static feeds | Enterprise networks with controlled outbound access |
| 3 | Physically disconnected | Offline bundles, a local CA, and media transfer | Disconnected sites, ships, remote field operations |
| 4 | Faraday cage / TEMPEST | Zero external dependency, signed artifacts, and full supply-chain control | High-security facilities and sensitive environments |

Design for the highest level you may ever face; lower levels come for free.

Every demo README must link to this file rather than redefine the levels.
