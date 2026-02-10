#!/bin/bash
plugin_name="csi.san.synology.com"

SCRIPT_PATH="$(realpath "$0")"
SOURCE_PATH="$(realpath "$(dirname "${SCRIPT_PATH}")"/../)"
config_file="${SOURCE_PATH}/config/client-info.yml"

# Configurable defaults
CSI_NAMESPACE="${CSI_NAMESPACE:-synology-csi}"
KUBELET_PATH="${KUBELET_PATH:-/var/lib/kubelet}"

source "$SOURCE_PATH"/scripts/functions.sh

# 1. Build
csi_build(){
    echo "==== Build synology-csi .... ===="
    source "$SOURCE_PATH"/build.sh
}

# 2. Install
csi_install(){
    echo "==== Creates namespace and secrets, then installs synology-csi ===="
    parse_version
    echo "Deploy Version: $deploy_k8s_version"
    echo "Namespace: $CSI_NAMESPACE"
    echo "Kubelet path: $KUBELET_PATH"

    local plugin_dir="${KUBELET_PATH}/plugins/${plugin_name}"
    local deploy_dir="$SOURCE_PATH/deploy/kubernetes/$deploy_k8s_version"

    # Create namespace (idempotent via apply)
    kubectl apply -f "$deploy_dir"/namespace.yml

    # If using a custom namespace, patch the namespace in all manifests via
    # kubectl's --namespace flag and create the namespace if it differs from
    # what namespace.yml defines.
    if [ "$CSI_NAMESPACE" != "synology-csi" ]; then
        echo "Using custom namespace: $CSI_NAMESPACE"
        kubectl create namespace "$CSI_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    fi

    kubectl create secret -n "$CSI_NAMESPACE" generic client-info-secret \
        --from-file="$config_file" \
        --dry-run=client -o yaml | kubectl apply -f -

    if [ ! -d "$plugin_dir" ]; then
        mkdir -p "$plugin_dir"
    fi

    # Apply manifests, overriding namespace if custom
    if [ "$CSI_NAMESPACE" != "synology-csi" ]; then
        # Use kustomize with namespace override if available, otherwise sed
        if command -v kustomize &> /dev/null || kubectl kustomize --help &> /dev/null 2>&1; then
            local tmpdir
            tmpdir=$(mktemp -d)
            trap "rm -rf $tmpdir" RETURN

            # Create a temporary kustomization that overrides namespace
            cat > "$tmpdir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${CSI_NAMESPACE}
resources:
  - $(realpath "$deploy_dir")
EOF
            kubectl apply -k "$tmpdir"
        else
            echo "ERROR: Custom namespace requires kustomize or kubectl with kustomize support."
            echo "Install kustomize or use kubectl v1.14+."
            exit 1
        fi
    else
        kubectl apply -f "$deploy_dir"
    fi

    if [ "$basic_mode" == false ]; then
        if [ "$CSI_NAMESPACE" != "synology-csi" ]; then
            local tmpdir_snap
            tmpdir_snap=$(mktemp -d)
            trap "rm -rf $tmpdir_snap" RETURN

            cat > "$tmpdir_snap/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${CSI_NAMESPACE}
resources:
  - $(realpath "$deploy_dir/snapshotter")
EOF
            kubectl apply -k "$tmpdir_snap"
        else
            kubectl apply -f "$deploy_dir"/snapshotter
        fi
    fi

    if [ "$openshift_mode" == true ]; then
        if [ "$CSI_NAMESPACE" != "synology-csi" ]; then
            # Patch the OpenShift SCC to use the custom namespace
            sed "s/synology-csi/${CSI_NAMESPACE}/g" \
                "$SOURCE_PATH"/deploy/kubernetes/openshift_synology_scc.yml \
                | kubectl apply -f -
        else
            kubectl apply -f "$SOURCE_PATH"/deploy/kubernetes/openshift_synology_scc.yml
        fi
    fi

    if [ "$talos_mode" == true ]; then
        kubectl patch daemonset \
            synology-csi-node \
            --namespace "$CSI_NAMESPACE" \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/1/args", "value": [
            "--nodeid=$(KUBE_NODE_NAME)",
            "--endpoint=$(CSI_ENDPOINT)",
            "--client-info",
            "/etc/synology/client-info.yml",
            "--log-level=info",
            "--iscsiadm-path=/usr/local/sbin/iscsiadm"
        ]}]'
    fi
}

# 3. Uninstall
csi_uninstall(){
    parse_version
    kubectl delete -f "$SOURCE_PATH"/deploy/kubernetes/$deploy_k8s_version --namespace "$CSI_NAMESPACE" || true
    kubectl delete -f "$SOURCE_PATH"/deploy/kubernetes/$deploy_k8s_version/snapshotter --namespace "$CSI_NAMESPACE" || true
    kubectl delete -f "$SOURCE_PATH"/deploy/kubernetes/openshift_synology_scc.yml || true
}

print_usage(){
    echo "Usage:"
    echo "    deploy.sh <command> [flags]"
    echo ""
    echo "Available Commands:"
    echo "    run                    build and install"
    echo "    build                  build docker image only"
    echo "    install [flags]        install csi plugin with the specified flags"
    echo "    uninstall              uninstall the csi plugin and snapshot controller"
    echo "    help                   show help"
    echo ""
    echo "Available Flags:"
    echo "    -a, --all              deploy csi plugin and snapshotter (default)"
    echo "    -b, --basic            deploy basic csi plugin only (no snapshotter)"
    echo "    -o, --openshift        deploy on OpenShift cluster (applies SCC)"
    echo "    -t, --talos            deploy on Talos cluster (patches iscsiadm path)"
    echo "    -n, --namespace NAME   set the Kubernetes namespace (default: synology-csi)"
    echo "    -k, --kubelet-path DIR set the kubelet root directory (default: /var/lib/kubelet)"
    echo ""
    echo "Environment Variables:"
    echo "    CSI_NAMESPACE          same as --namespace (flag takes precedence)"
    echo "    KUBELET_PATH           same as --kubelet-path (flag takes precedence)"
    echo ""
    echo "Examples:"
    echo "    deploy.sh run"
    echo "    deploy.sh install --basic"
    echo "    deploy.sh install --namespace my-csi-ns"
    echo "    deploy.sh install --namespace my-csi-ns --kubelet-path /var/lib/k0s/kubelet"
    echo "    CSI_NAMESPACE=my-csi-ns deploy.sh install"
}

basic_mode=false
openshift_mode=false
talos_mode=false

parse_flags(){
    while [ $# -gt 0 ]; do
        case "$1" in
            -a|--all)
                ;;
            -b|--basic)
                basic_mode=true
                ;;
            -o|--openshift)
                openshift_mode=true
                ;;
            -t|--talos)
                talos_mode=true
                ;;
            -n|--namespace)
                shift
                if [ -z "$1" ]; then
                    echo "ERROR: --namespace requires a value"
                    exit 1
                fi
                CSI_NAMESPACE="$1"
                ;;
            -k|--kubelet-path)
                shift
                if [ -z "$1" ]; then
                    echo "ERROR: --kubelet-path requires a value"
                    exit 1
                fi
                KUBELET_PATH="$1"
                ;;
            *)
                echo "Unknown flag: $1"
                print_usage
                exit 1
                ;;
        esac
        shift
    done
}

case "$1" in
    build)
        csi_build
        ;;
    install)
        shift
        parse_flags "$@"
        csi_install
        ;;
    run)
        shift
        parse_flags "$@"
        csi_build
        csi_install
        ;;
    uninstall)
        shift
        parse_flags "$@"
        csi_uninstall
        ;;
    help|-h|--help)
        print_usage
        ;;
    *)
        print_usage
        exit 1
        ;;
esac
