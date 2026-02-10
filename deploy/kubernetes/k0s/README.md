# Deploying Synology CSI on k0s

This overlay adapts the Synology CSI driver for [k0s](https://k0sproject.io/)
clusters, where the kubelet root directory is `/var/lib/k0s/kubelet/` instead of
the standard `/var/lib/kubelet/`.

## What This Overlay Changes

The k0s Kustomize overlay patches the `synology-csi-node` DaemonSet to replace
all `/var/lib/kubelet` paths with `/var/lib/k0s/kubelet/`:

- `REGISTRATION_PATH` environment variable (CSI socket registration)
- `kubelet-dir` volume mount in the `csi-plugin` container
- `kubelet-dir`, `plugin-dir`, and `registration-dir` hostPath volumes

No changes are made to the controller StatefulSet (it does not use kubelet paths).

## Prerequisites

1. A running k0s cluster (v1.25+)
2. `kubectl` configured to access the cluster
3. A Synology NAS with iSCSI service enabled
4. `client-info-secret` containing NAS connection details (see below)

## Quick Start

There are two deployment methods: **Kustomize** (recommended) or `deploy.sh`.

### Option A: Deploy with Kustomize

#### 1. Create the Namespace and Secret

```bash
kubectl create namespace synology-csi

kubectl create secret generic client-info-secret \
  --namespace synology-csi \
  --from-file=client-info.yml=<path-to-your-client-info.yml>
```

#### 2. Customize the StorageClass

Edit `deploy/kubernetes/v1.25/storage-class.yml` to set parameters for your
environment:

```yaml
parameters:
  dsm: 10.0.0.100
  location: /volume1
  fsType: ext4              # Recommended: prevents fsGroup permission issues
  clusterName: my-cluster   # Optional: tags LUN descriptions for multi-cluster
```

#### 3. Deploy

```bash
kubectl apply -k deploy/kubernetes/k0s/
```

Or preview the rendered manifests first:

```bash
kubectl kustomize deploy/kubernetes/k0s/
```

### Option B: Deploy with deploy.sh

The `deploy.sh` script supports `--namespace` and `--kubelet-path` flags for
k0s deployments:

```bash
./scripts/deploy.sh install \
  --namespace synology-csi \
  --kubelet-path /var/lib/k0s/kubelet
```

Or use environment variables:

```bash
export CSI_NAMESPACE=synology-csi
export KUBELET_PATH=/var/lib/k0s/kubelet
./scripts/deploy.sh install
```

Run `./scripts/deploy.sh help` for all available flags.

### Verify

```bash
kubectl -n synology-csi get pods
kubectl get csidriver csi.san.synology.com
kubectl get storageclass
```

## Custom Namespace

Both deployment methods support deploying into a namespace other than the
default `synology-csi`.

### Kustomize

Uncomment the `namespace` line in `deploy/kubernetes/k0s/kustomization.yaml`:

```yaml
namespace: my-custom-csi-ns
```

This rewrites all namespace references in the rendered manifests. Then create
the secret in your custom namespace before applying:

```bash
kubectl create namespace my-custom-csi-ns

kubectl create secret generic client-info-secret \
  --namespace my-custom-csi-ns \
  --from-file=client-info.yml=<path-to-your-client-info.yml>

kubectl apply -k deploy/kubernetes/k0s/
```

### deploy.sh

```bash
./scripts/deploy.sh install \
  --namespace my-custom-csi-ns \
  --kubelet-path /var/lib/k0s/kubelet
```

The script handles namespace creation and manifest rewriting automatically.

## The `client-info.yml` File

```yaml
clients:
  - host: <nas-ip>
    port: 5001
    https: true
    username: <csi-username>
    password: <csi-password>
    # Optional: override the network interface for iSCSI traffic
    # clientsubnetoverride: "10.0.0.0/24"
```

## Adapting for Other Distributions

This overlay pattern can be adapted for any Kubernetes distribution that uses a
non-standard kubelet root directory. To create an overlay for another
distribution:

1. Copy the `k0s/` directory to a new directory (e.g., `microk8s/`)
2. Edit `node-kubelet-path-patch.yaml` and replace `/var/lib/k0s/kubelet` with
   the correct path for your distribution
3. Update `kustomization.yaml` if needed

Common kubelet paths by distribution:

| Distribution | Kubelet Root |
|-------------|-------------|
| Standard (kubeadm, RKE2, etc.) | `/var/lib/kubelet` |
| k0s | `/var/lib/k0s/kubelet` |
| Talos | `/var/lib/kubelet` (standard) |
| MicroK8s | `/var/snap/microk8s/common/var/lib/kubelet` |

Alternatively, use `deploy.sh` with `--kubelet-path`:

```bash
./scripts/deploy.sh install --kubelet-path /var/snap/microk8s/common/var/lib/kubelet
```

## Important Notes

### fsType Parameter

The `fsType: ext4` parameter in the StorageClass is **strongly recommended**.
Without it, Kubernetes may skip `fsGroup` ownership changes on mounted volumes,
causing permission errors for non-root workloads. The underlying filesystem is
always ext4 regardless of this setting, but the metadata must be explicit for
`fsGroupPolicy: ReadWriteOnceWithFSType` to work correctly.

### clusterName Parameter

The `clusterName` parameter (from the xphyr fork) prepends a cluster identifier
to LUN descriptions on the NAS, making it possible to identify which cluster
owns each volume in multi-cluster environments. The format becomes:

```
<clusterName>/<namespace>/<pvcName>
```

### Snapshotter

Volume snapshots require additional CRDs and the snapshot controller. To include
the snapshotter resources, add them to `kustomization.yaml`:

```yaml
resources:
  - ../v1.25
  - ../v1.25/snapshotter/snapshotter.yaml
  - ../v1.25/snapshotter/volume-snapshot-class.yml
```
