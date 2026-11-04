# Offline monitoring stack

An example set up to demonstrate taking our example monitoring stack offline with Zarf and Hauler.

Original set up from: <https://github.com/telemetryforge/fluent-bit-examples/tree/main/monitoring-stack>.
This includes a few components:

* kube-prometheus-stack helm chart
  * Loki, Prometheus and Grafana images required
  * Custom Grafana dashboard
* fluent-bit helm chart
  * OSS Fluent Bit image
  * FluentDo Agent image
  * Forwarder (Daemonset) --> Aggregator (Deployment) model

## Zarf.dev

Some useful commands are `zarf dev find-images` which will give you all the images you need plus signatures, etc.

We follow the simple steps here: <https://docs.zarf.dev/best-practices/airgap-demos/>.

```shell
zarf package create .
```

We can specify an architecture as well, e.g. `--architecture arm64`.
We can also create differential packages with `--differential`: <https://docs.zarf.dev/tutorials/9-package-create-differential/>.

Set up the demo cluster, this would be done however you normally do it with `zarf tools download-init` giving you a package to install as well:

```shell
kind create cluster
zarf tools download-init
```

Disconnect from network optionally to demonstrate it - but may break the presentation!

```shell
zarf init --confirm --components=git-server
zarf package deploy ./zarf-package-*.zst --confirm
```

You can even deploy a k3s cluster as well: `zarf init --components k3s,git-server --confirm`

Connect to Grafana with `admin:prom-operator` credentials by default:

```shell
zarf connect grafana-dashboard
```

Get credentials and do port-forward directly:

```shell
kubectl --namespace monitoring get secrets kube-prom-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo
kubectl --namespace monitoring port-forward \
    "$(kubectl --namespace monitoring get pod -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prom-stack" -oname)" \
    3000
```

To remove Zarf components:

```shell
zarf destroy --confirm
```

This will remove the container registry, gitea server and all Zarf components but not the package you have deployed - although images will need mirroring somewhere.

Issues:

* `unable to find pod attached to given resource: unable to find the service: services "zarf-gitea-http" not found`
  * Missing git server during: `zarf init --confirm --components=git-server`

## Hauler

Relies on getting all images from the cluster.

```shell
# fetch all images in the cluster, remove duplicates, alphabetize, and put on a newline
export IMAGE_LIST=$(kubectl get pods --all-namespaces -o jsonpath="{.items[*].spec.containers[*].image}" | sed 's/ /\n/g' | sort | uniq)
# add the required formatting for the image list
export IMAGE_LIST_MODIFIED=$(echo "${IMAGE_LIST}" | sed 's/^/    - name: /')

# create the hauler manifest with the updated image list
cat << EOF > hauler-manifest.yaml
apiVersion: content.hauler.cattle.io/v1
kind: Images
metadata:
  name: hauler-cluster-images
spec:
  images:
$IMAGE_LIST_MODIFIED
EOF
```

No signatures retrieved this way of course.

We can retrieve "files" though as well, rather than just OCI images and charts.

Example workflow here: <https://docs.hauler.dev/docs/introduction/quickstart>.

Detain all required binaries and charts:

```shell
hauler store sync --filename hauler-manifest.yaml
hauler store info
```

Architecture can be configured or specified via `--platform arm64` flag but by default it seems to grab all.

Bundle up to a tarball:

```shell
hauler store save --filename haul.tar.zst
```

Now we can copy `haul.tar.zst` over to where it is needed.

```shell
# load and import the airgapped content to the new local hauler store
hauler store load --filename haul.tar.zst
```

Now you can serve the files and images locally or copy them to a running registry and/or extract to a local directory.

Run up a local registry:

```shell
kubectl apply -f registry.yaml
kubectl port-forward svc/registry 5000:5000
```

Push to the local registry:

```shell
hauler store copy registry//localhost:5000
```

In real life we would have a proper registry set up.

We can see all the artefacts uploaded now including raw binaries for k9s:

```shell
$ curl http://localhost:5000/v2/_catalog
{"repositories":["bats/bats","fluent/fluent-bit","fluentdo/agent","grafana/grafana","hauler/fluent-bit","hauler/k9s_linux_amd64.tar.gz","hauler/k9s_linux_arm64.tar.gz","hauler/kube-prometheus-stack","ingress-nginx/kube-webhook-certgen","kiwigrid/k8s-sidecar","kube-state-metrics/kube-state-metrics","library/busybox","prometheus/alertmanager","prometheus/node-exporter","prometheus/prometheus","prometheus-operator/prometheus-config-reloader","prometheus-operator/prometheus-operator","thanos/thanos"]}
```

Now we can run up using the private registry.
