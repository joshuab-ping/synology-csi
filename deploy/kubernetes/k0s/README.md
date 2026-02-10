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

### 1. Create the Namespace and Secret

```bash
kubectl create namespace synology-csi

kubectl create secret generic client-info-secret \
  --namespace synology-csi \
  --from-file=client-info.yml=<path-to-your-client-info.yml>
```

The `client-info.yml` file should look like:

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

### 2. Customize the StorageClass

Edit `deploy/kubernetes/v1.25/storage-class.yml` to set parameters for your
environment:

```yaml
parameters:
  dsm: '<nas-ip>'
  location: '/volume1'
  fsType: 'ext4'          # Recommended: prevents fsGroup permission issues
  clusterName: 'my-cluster'  # Optional: tags LUN descriptions for multi-cluster
```

### 3. Deploy with Kustomize

```bash
kubectl apply -k deploy/kubernetes/k0s/
```

Or preview the rendered manifests first:

```bash
kubectl kustomize deploy/kubernetes/k0s/
```

### 4. Verify

```bash
kubectl -n synology-csi get pods
kubectl get csidriver csi.san.synology.com
kubectl get storageclass
```

## Adapting for Other Distributions

This overlay pattern can be adapted for any Kubernetes distribution that uses a
non-standard kubelet root directory. To create an overlay for another
distribution:

1. Copy the `k0s/` directory to a new directory (e.g., `talos/`, `microk8s/`)
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

## Important Notes

### fsType Parameter

The `fsType: 'ext4'` parameter in the StorageClass is **strongly recommended**.
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
