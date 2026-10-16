# Taking cloud-native offline: deployment-time trust

## Story

"We checked the image when it crossed the boundary. Who checks the next Pod?"

Transfer verification establishes what arrived. Admission enforces what is
allowed to execute, including a developer deploying another tag later.
This demo keeps the decision, registry, signatures and trust root local.
The application is the same go-httpbin release in all three cases, not three
unrelated applications selected to produce different policy results.

## Preparation

- Run [the orchestrator](./scripts/run-demo.sh) once on the presentation machine.
  Rehearse with `DEMO_PAUSE_SECONDS=0`; the recorded successful run took 159s
  with downloads cached, excluding cold downloads and narration pauses.
- Use native Linux amd64 with privileged rootful Docker and cgroup v2.
  Reserve the documented subnets and names. Do not use a production cluster.
- The Notation test certificate lasts about one day. Rerun on the day; it
  generates a fresh key/cert and repopulates a fresh registry.
- Enlarge the terminal enough to see the full admission denial. Use
  `DEMO_PAUSE_SECONDS=8` for longer narration pauses; defaults are two seconds.
  Redirect through `tee` to keep the entire transcript without terminal clears.
- Keep [the README](./README.md) and
  [the trust policy](./config/trustPolicy.json) open. Do not show private state,
  registry credentials or a `bash -x` transcript.
- Do not present a failed probe/bootstrap as a successful air gap. Read the
  actual result file and exact denial text from the current run.

## Key beats in one terminal

### CONNECTED: phase 1

"We can buy dependencies now. We cannot buy them after the boundary closes."

Show the version/digest pins. Notation and both charts have archive checksums.
Images and tooling are staged before isolation. No public Helm repository is
consulted during admission.

### CONNECTED: phase 2

"A tag is not an identity. The signature follows the digest."

Explain the trap before showing the result:

- `signed`: original digest, signed with our local test identity.
- `unsigned`: same binary/layers, config-only label so it really is a different
  unsigned manifest. A second tag pointing at the signed digest would verify.
- `tampered`: originally resolves to the signed digest and verifies, then the
  same tag is overwritten by a build with one added layer.

The public trust-only bundle has a certificate and policy, **not** a private
key. Signing happens on the host; verification happens in Ratify.

### CONNECTED: phases 3-4

"Kubernetes NetworkPolicy is an API. A policy controller must enforce it."

kindnet alone is insufficient; kube-router supplies the policy enforcement.
The positive public probe works before policy. After default-deny, the Pod's
probe fails while the node's succeeds. That distinction demonstrates enforcement
rather than just claiming the CNI supports the object.

Explain the second boundary: NetworkPolicy does not cover node image pulls or
host-networked control-plane components. The orchestrator seals node OUTPUT
and FORWARD, denies external IPv6, and removes the default route before moving
to the AIR-GAPPED banner. zot has been internal-only throughout.

### AIR-GAPPED: phase 5

"The node, the Pod and the verifier all lose public access; local services stay."

Point out the direct-IP probe, public-DNS probe and Ratify network-namespace
probe. This is a software-enforced disconnected enclave, not an unplugged host.
The node retains its Docker attachment to preserve its control-plane address;
the missing route and in-container firewall are the node enforcement boundary.

The host is still connected and trusted. All remaining API operations execute
the node-local kubectl through Docker, not a public endpoint or manifest URL.

### AIR-GAPPED: phase 6

"Trust decisions still work when the public trust services are absent."

1. Signed Pod becomes Ready. Show its digest-pinned reference and real go-httpbin
   `/get?demo=offline` response.
2. Unsigned Pod gets a validating admission denial, not ImagePullBackOff.
3. Overwritten `tampered` tag gets the same explicit signature requirement.
4. Final public probes still fail. PASS appears only after all assertions.

No rejected Pod exists, so there is no Pod Event to show. The exact API response
and Ratify trace ID are the denial evidence.

## Likely questions

**"Is this just a cached verification result?"**  
No. Ratify/ORAS/Gatekeeper external-data response caches are disabled. The cluster
does not verify the application before isolation, and the app is not preloaded
into node containerd. The successful Pod pulls from local zot after sealing.

**"Did you alter signed bytes while keeping the same digest?"**  
No. Content-addressed storage would reject that. We produced a valid new image
with one extra filesystem layer and moved the tag. Its new digest has no
authorized signature. The old signature still authenticates the old digest.

**"Is the unsigned case actually the same app?"**  
Yes: same go-httpbin binary and filesystem layers. A harmless config label gives
the manifest a distinct digest, essential because referrers are digest-scoped.

**"Why use a self-signed cert?"**  
It makes the trust boundary visible. The deployed public trust anchor and exact
subject identity are the whole signing authority for this demo. Real systems
need protected keys, a real PKI/rotation process, trusted time and compromise
response. This test cert expires in about 24 hours.

**"What about Rekor/TUF/Fulcio?"**  
None participates in this decision. Local PKI trades public identity/transparency
services for operator-managed trust. Do not say "Sigstore cannot work offline":
bundled keyless evidence can be verified offline under an appropriate policy.

**"Why HTTP and two sets of credentials?"**  
HTTP is deliberate sandbox transport, not a production recommendation. Ratify
authenticates through its service-account pull secret; kubelet/containerd uses
the Pod pull secret and endpoint-specific HTTP configuration. Registry TLS
trust would be separate from the Notation signing certificate.

**"Why keep the node on an external Docker bridge?"**  
The tested kind image cannot start without a default route, and removing its
advertised node IP would break the control plane. Node-local firewall rules and
route removal isolate it without changing the Docker host. This is explicitly
documented, not presented as an all-internal Docker topology.

**"What fails when Ratify is unavailable?"**  
The demo namespace has fail-closed admission. Availability is deliberately a
trade-off; outage/recovery is not part of this tested run. The policy does not
cover every namespace or harden privileged workloads.

**"Can the host or a malicious privileged workload bypass this?"**  
Yes. The host is trusted, and production needs RBAC and privilege/network
restrictions. This is not a hardened hostile multi-tenant boundary.

**"Could this require an SBOM too?"**  
Yes, but not merely the presence of arbitrary SBOM bytes. Bind verified SBOM
evidence to the image digest and require both that evidence and the image
signature. The README marks that and cosign-referrer experiments as untested
stretch goals, not working features.

## Finish and recovery

Return to: "Offline is a locally complete decision, not just a cached image."

Show [the cleanup command](./scripts/cleanup.sh):

```bash
./scripts/cleanup.sh
```

It removes only demo containers/networks, not host firewall rules or shared
images. Generated evidence and private state remain ignored for diagnosis.
On failure, keep the transcript, inspect the actual error, and rerun from the
beginning while connected. Do not repair isolation live by reopening internet
and continue to call the result air-gapped.
