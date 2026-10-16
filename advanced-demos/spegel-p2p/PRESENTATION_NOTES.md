# Presentation notes

## Story

“A registry is a coordination point for acquiring an image, but it need not
remain a bandwidth bottleneck for every node. What if the node that already has
the layers could serve the next node directly?”

Start with three k3d nodes and a throwaway local registry. Only agent 0 has
Redis in containerd. Then take the registry away, block node and pod egress
with per-node iptables rules, and let Kubernetes create three `Always`-pull
pods. Agent 1 must get its missing image through a Spegel peer.

## Key beats

1. **Frame the boundary:** the Docker host is connected for provisioning. At
   the outage boundary the script stops the local registry, then applies
   iptables `OUTPUT` and `FORWARD` egress blocks inside each k3d node. This is
   an air-gap simulation for the cluster data plane, not a physically
   disconnected host.
2. **Show the prerequisite that makes Spegel work:** the k3s-specific
   containerd v3 patch selects overlayfs and sets
   `discard_unpacked_layers = false`. Explain that Spegel can only share
   content the node's containerd still retains.
3. **Make the asymmetry explicit:** show agent 0's image record and agent 1's
   missing image record before the outage. Spegel's own image is preloaded on
   every node so it doesn't need a registry to start.
4. **Remove the fallback:** the registry is stopped. Point to the external
   HTTP probe failures and increasing iptables reject counters on each node
   before applying the Deployment.
5. **Read the evidence:** one Redis pod is Running on agent 1, the Redis image
   is now in agent 1 containerd, the agent-0 Spegel log is printed, and the
   requester reports `spegel_mirror_requests_total` with `cache="hit"`.
6. **Close honestly:** without Spegel, the pull falls back to the unavailable
   registry and the pod reaches `ImagePullBackOff`. Spegel distributes
   existing cluster content; it does not eliminate the need to stage the
   cluster and its initial images.

## Likely questions

- **Is this a full air gap?** No. Per-node iptables rules block external
  `OUTPUT` and `FORWARD` traffic while preserving node and Kubernetes
  in-cluster CIDRs; the registry is stopped. The host still has Docker access
  and can have internet access.
- **Why configure containerd instead of only using a Kubernetes mirror?**
  Spegel is a containerd registry mirror and serves content from containerd's
  retained content store. The K3s paths and configuration format differ from
  a generic upstream containerd install. The chart is configured to mirror
  the demo's `http://registry:5000` hostname; unrelated Docker Hub pulls for
  Kubernetes system components continue to use their normal registry.
- **Why must `discard_unpacked_layers` be false?** Spegel needs the content
  store data to remain available for peers after images are unpacked. The
  config patch also explicitly retains the overlayfs snapshotter and isolated
  content sharing policy used by Spegel's containerd setup.
- **Does every new node get an image without any seed?** No. At least one
  reachable peer must have the requested manifest and blobs. Otherwise the
  pull fails just as it would with the central registry unavailable.
- **What if the registry disappears mid-download?** This demo stops it before
  scheduling. Real deployments should test partial transfers, peer loss,
  retries and fallback behavior under their own network conditions.
- **Is `redis:alpine` reproducible?** The tag is intentionally mutable per the
  demo request. The actual digest is printed in containerd/Docker output; use
  a digest-pinned reference in a production release process.
- **Does Spegel replace an image registry?** It distributes images that
  already exist in cluster nodes. It is not a registry for authoring,
  retention, policy, or initial cluster bootstrap.

## Presenter controls

Run `./scripts/run-demo.sh` and press Enter at the phase boundary. Use
`DEMO_AUTO_ADVANCE=1` only for an unattended timed rehearsal. The script
automatically cleans up all demo resources and reports total runtime.
