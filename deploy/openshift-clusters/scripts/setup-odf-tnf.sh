#!/bin/bash
#
# Automate post-TNF OCP setup for ODF + DRBD on a two-node fencing cluster.
#
# Run from a toolbox clone root (or deploy/). The script cds into deploy/,
# sources common.sh + openshift-clusters/proxy.env, then does the rest.
#
#   cd /path/to/two-node-toolbox-1   # or -2
#   curl -fsSL https://raw.githubusercontent.com/malayparida2000/two-node-toolbox/personal/setup-odf-tnf/deploy/openshift-clusters/scripts/setup-odf-tnf.sh | bash
#
set -euo pipefail

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != */dev/fd/* && "${BASH_SOURCE[0]}" != /dev/fd/* ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

DEPLOY_DIR="${DEPLOY_DIR:-}"
DEPLOY_DIR_FROM_FLAG=0

#------------------------------------------------------------------------------
# Defaults (override via env or flags)
#------------------------------------------------------------------------------
POOL="${POOL:-test}"
DIR="${DIR:-/test}"
SIZE_SMALL="${SIZE_SMALL:-10G}"
SIZE_LARGE="${SIZE_LARGE:-256G}"
# Guest device names — must match PV paths and DRBD -d.
DEV_SMALL="${DEV_SMALL:-sdb}"
DEV_LARGE="${DEV_LARGE:-sdc}"
VM0="${VM0:-}"
VM1="${VM1:-}"

ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"
STORAGE_CLASS="${STORAGE_CLASS:-local-storage}"
PV_CAPACITY="${PV_CAPACITY:-100Gi}"
PV_PATH="${PV_PATH:-/dev/${DEV_LARGE}}"
DRBD_DEVICE="${DRBD_DEVICE:-/dev/${DEV_SMALL}}"

OCS_REGISTRY_IMAGE="${OCS_REGISTRY_IMAGE:-quay.io/rhceph-dev/ocs-registry:5.0.0-67.konflux}"
ODF_CHANNEL="${ODF_CHANNEL:-stable}"
ODF_PACKAGE="${ODF_PACKAGE:-openshift-data-foundation}"
CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-redhat-operators}"

STORAGECLUSTER_NAME="${STORAGECLUSTER_NAME:-ocs-storagecluster}"
DEVICESET_NAME="${DEVICESET_NAME:-ocs-deviceset}"

WAIT_CATALOG_TIMEOUT="${WAIT_CATALOG_TIMEOUT:-600}"
WAIT_CSV_TIMEOUT="${WAIT_CSV_TIMEOUT:-900}"
WAIT_DRBD_CM_TIMEOUT="${WAIT_DRBD_CM_TIMEOUT:-600}"
WAIT_STORAGECLUSTER_TIMEOUT="${WAIT_STORAGECLUSTER_TIMEOUT:-1800}"

SKIP_DISKS=0
SKIP_STORAGE=0
SKIP_CATALOG=0
SKIP_ODF=0
SKIP_DRBD=0
SKIP_LABELS=0
SKIP_STORAGECLUSTER=0
DRY_RUN=0

WORKDIR=""
SSH_CMD=()

usage() {
  cat <<EOF
Usage: run from a toolbox clone root (or deploy/):

  curl -fsSL https://raw.githubusercontent.com/malayparida2000/two-node-toolbox/personal/setup-odf-tnf/deploy/openshift-clusters/scripts/setup-odf-tnf.sh | bash

Options:
  --deploy-dir DIR        Path to that clone's deploy/ (default: cwd)
  --skip-disks            Skip libvirt pool/volume/attach
  --skip-storage          Skip StorageClass + PV apply
  --skip-catalog          Skip OperatorHub patch + CatalogSource
  --skip-odf              Skip ODF Subscription
  --skip-drbd             Skip DRBD setup script
  --skip-labels           Skip node labeling
  --skip-storagecluster   Skip StorageCluster create
  --dry-run               Print actions without applying
  -h, --help              Show this help
EOF
}

resolve_deploy_dir() {
  local candidate=""
  if [[ "${DEPLOY_DIR_FROM_FLAG}" -eq 1 || -n "${DEPLOY_DIR}" ]]; then
    candidate="${DEPLOY_DIR}"
  elif [[ -f ./deploy/common.sh ]]; then
    candidate="./deploy"
  elif [[ -f ./common.sh ]]; then
    candidate="."
  elif [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/../../common.sh" ]]; then
    candidate="${SCRIPT_DIR}/../.."
  else
    echo "ERROR: run this from a two-node-toolbox clone root (or deploy/)." >&2
    echo "  cd /path/to/two-node-toolbox-1   # or -2" >&2
    echo "  curl -fsSL .../setup-odf-tnf.sh | bash" >&2
    exit 1
  fi
  DEPLOY_DIR="$(cd "${candidate}" && pwd)"
  [[ -f "${DEPLOY_DIR}/common.sh" ]] || {
    echo "ERROR: ${DEPLOY_DIR}/common.sh not found" >&2
    exit 1
  }
}

# Parse args before cd/source so --help works anywhere.
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --deploy-dir requires a path" >&2; exit 1; }
      DEPLOY_DIR="$2"
      DEPLOY_DIR_FROM_FLAG=1
      shift 2
      ;;
    --deploy-dir=*)
      DEPLOY_DIR="${1#*=}"
      DEPLOY_DIR_FROM_FLAG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

resolve_deploy_dir
cd "${DEPLOY_DIR}"

# shellcheck source=/dev/null
source "${DEPLOY_DIR}/common.sh"

PROXY_ENV="${DEPLOY_DIR}/openshift-clusters/proxy.env"
if [[ -f "${PROXY_ENV}" ]]; then
  # shellcheck source=/dev/null
  source "${PROXY_ENV}"
  echo "==> cd ${DEPLOY_DIR} && sourced openshift-clusters/proxy.env"
else
  echo "WARNING: ${PROXY_ENV} not found; relying on existing KUBECONFIG/proxy env" >&2
fi

#------------------------------------------------------------------------------
# Helpers (after common.sh so msg_* are available)
#------------------------------------------------------------------------------
log()  { echo "==> $*"; }
warn() { msg_warning "$*"; }
die()  { msg_err "$*"; exit 1; }

run_oc() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN oc $*"
    return 0
  fi
  oc "$@"
}

wait_for() {
  local desc="$1" timeout="$2"
  shift 2
  local start now
  start=$(date +%s)
  log "Waiting for ${desc} (timeout ${timeout}s)..."
  while true; do
    if "$@"; then
      log "${desc}: OK"
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      die "Timed out waiting for ${desc} after ${timeout}s"
    fi
    sleep 10
  done
}

#------------------------------------------------------------------------------
# Remaining args
#------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-disks) SKIP_DISKS=1 ;;
    --skip-storage) SKIP_STORAGE=1 ;;
    --skip-catalog) SKIP_CATALOG=1 ;;
    --skip-odf) SKIP_ODF=1 ;;
    --skip-drbd) SKIP_DRBD=1 ;;
    --skip-labels) SKIP_LABELS=1 ;;
    --skip-storagecluster) SKIP_STORAGECLUSTER=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

#------------------------------------------------------------------------------
# Preflight
#------------------------------------------------------------------------------
preflight() {
  local node_dir

  command -v oc >/dev/null 2>&1 || die "oc not found in PATH"
  run_oc get nodes >/dev/null 2>&1 || die "Cannot reach cluster API (oc get nodes failed). Is the cluster up and proxy.env present?"

  local not_ready
  not_ready="$(oc get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}' || true)"
  if [[ -n "${not_ready}" ]]; then
    die "Nodes not Ready: ${not_ready}"
  fi

  if [[ "${SKIP_DISKS}" -eq 0 ]]; then
    node_dir="$(get_node_dir)"
    [[ -f "${node_dir}/public_address" ]] || die "Missing ${node_dir}/public_address (run make inventory / make deploy first)"
    [[ -f "${node_dir}/ssh_user" ]] || die "Missing ${node_dir}/ssh_user"

    local instance_ip ssh_user ssh_key_opts=()
    instance_ip="$(tr -d '\n' < "${node_dir}/public_address")"
    ssh_user="$(tr -d '\n' < "${node_dir}/ssh_user")"
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
      ssh_key_opts=(-i "${SSH_PUBLIC_KEY%.pub}")
    fi
    SSH_CMD=(ssh "${ssh_key_opts[@]}" -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o BatchMode=yes "${ssh_user}@${instance_ip}")
    "${SSH_CMD[@]}" "true" >/dev/null 2>&1 || die "Cannot SSH to ${ssh_user}@${instance_ip}"
  fi

  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/setup-odf-tnf.XXXXXX")"
  trap 'rm -rf "${WORKDIR}"' EXIT

  log "Cluster nodes:"
  oc get nodes -o wide
}

discover_vms() {
  if [[ -n "${VM0}" && -n "${VM1}" ]]; then
    return 0
  fi
  log "Discovering master VMs on hypervisor..."
  local vms
  vms="$("${SSH_CMD[@]}" "sudo virsh list --all --name 2>/dev/null | grep -E '_master_0$|_master_1$|master-0$|master-1$' | sort" || true)"
  if [[ -z "${vms}" ]]; then
    # Fallback: any two running domains containing master
    vms="$("${SSH_CMD[@]}" "sudo virsh list --name 2>/dev/null | grep -i master | sort" || true)"
  fi
  VM0="$(echo "${vms}" | awk 'NR==1{print}')"
  VM1="$(echo "${vms}" | awk 'NR==2{print}')"
  [[ -n "${VM0}" && -n "${VM1}" ]] || die "Could not discover VM0/VM1. Set VM0=... VM1=... explicitly."
  log "Using VMs: VM0=${VM0} VM1=${VM1}"
}

discover_node_names() {
  # Sorted OpenShift node names (master-0 before master-1 typically).
  local nodes node_count
  nodes="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)"
  node_count="$(printf '%s\n' "${nodes}" | grep -c . || true)"
  if [[ "${node_count}" -lt 2 ]]; then
    die "Expected at least 2 nodes, found ${node_count}"
  fi
  NODE0="$(printf '%s\n' "${nodes}" | sed -n '1p')"
  NODE1="$(printf '%s\n' "${nodes}" | sed -n '2p')"
  log "Using OCP nodes for PVs: NODE0=${NODE0} NODE1=${NODE1}"
}

#------------------------------------------------------------------------------
# Phase 1: libvirt disks
#------------------------------------------------------------------------------
create_disks() {
  [[ "${SKIP_DISKS}" -eq 1 ]] && { log "Skipping disk creation"; return 0; }
  discover_vms

  log "Creating libvirt pool/volumes and attaching disks (pool=${POOL}, small=${DEV_SMALL}/${SIZE_SMALL}, large=${DEV_LARGE}/${SIZE_LARGE})"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN: would create pool ${POOL} at ${DIR} and attach vols to ${VM0}/${VM1}"
    return 0
  fi

  # shellcheck disable=SC2087
  "${SSH_CMD[@]}" bash -s <<REMOTE
set -euo pipefail
POOL="${POOL}"
DIR="${DIR}"
SIZE_SMALL="${SIZE_SMALL}"
SIZE_LARGE="${SIZE_LARGE}"
DEV_SMALL="${DEV_SMALL}"
DEV_LARGE="${DEV_LARGE}"
VM0="${VM0}"
VM1="${VM1}"

sudo mkdir -p "\$DIR"

if ! sudo virsh pool-info "\$POOL" >/dev/null 2>&1; then
  sudo virsh pool-define-as --name "\$POOL" --type dir --target "\$DIR"
  sudo virsh pool-build "\$POOL"
fi
sudo virsh pool-start "\$POOL" >/dev/null 2>&1 || true
sudo virsh pool-autostart "\$POOL" >/dev/null 2>&1 || true

create_vol() {
  local name="\$1" size="\$2"
  if sudo virsh vol-info --pool "\$POOL" "\$name" >/dev/null 2>&1; then
    echo "Volume \$name already exists"
  else
    sudo virsh vol-create-as --pool "\$POOL" --name "\$name" --capacity "\$size" --format qcow2
  fi
}

create_vol vol_0_small "\$SIZE_SMALL"
create_vol vol_1_small "\$SIZE_SMALL"
create_vol vol_0_large "\$SIZE_LARGE"
create_vol vol_1_large "\$SIZE_LARGE"

disk_attached() {
  local vm="\$1" dev="\$2"
  sudo virsh dumpxml "\$vm" | grep -q "<target dev='\${dev}'"
}

attach_disk() {
  local vm="\$1" vol="\$2" dev="\$3"
  if disk_attached "\$vm" "\$dev"; then
    echo "Disk \${dev} already attached to \${vm}"
    return 0
  fi
  sudo virsh attach-device "\$vm" /dev/stdin --persistent <<EOF
<disk type='volume' device='disk'>
  <driver name='qemu' type='qcow2' discard='unmap'/>
  <source pool='\${POOL}' volume='\${vol}'/>
  <target dev='\${dev}' bus='scsi' rotation_rate='1'/>
</disk>
EOF
  echo "Attached \${vol} as \${dev} on \${vm}"
}

attach_disk "\$VM0" vol_0_small "\$DEV_SMALL"
attach_disk "\$VM1" vol_1_small "\$DEV_SMALL"
attach_disk "\$VM0" vol_0_large "\$DEV_LARGE"
attach_disk "\$VM1" vol_1_large "\$DEV_LARGE"
REMOTE

  log "Disks attached. Giving guests a few seconds to see them..."
  sleep 5

  # Best-effort visibility check (oc debug can be slow / flaky; warn only).
  discover_node_names
  local node
  for node in "${NODE0}" "${NODE1}"; do
    if oc debug "node/${node}" --quiet -- chroot /host test -b "${DRBD_DEVICE}" 2>/dev/null \
      && oc debug "node/${node}" --quiet -- chroot /host test -b "${PV_PATH}" 2>/dev/null; then
      log "Verified ${DRBD_DEVICE} and ${PV_PATH} exist on ${node}"
    else
      warn "Could not verify ${DRBD_DEVICE}/${PV_PATH} on ${node} via oc debug. If attach used different target names, set DEV_SMALL/DEV_LARGE accordingly."
    fi
  done
}

#------------------------------------------------------------------------------
# Phase 2: StorageClass + PVs
#------------------------------------------------------------------------------
create_local_storage() {
  [[ "${SKIP_STORAGE}" -eq 1 ]] && { log "Skipping StorageClass/PVs"; return 0; }
  discover_node_names

  log "Applying StorageClass ${STORAGE_CLASS} and block PVs on ${PV_PATH} (${PV_CAPACITY})"

  run_oc apply -f - <<EOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: ${STORAGE_CLASS}
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
---
kind: PersistentVolume
apiVersion: v1
metadata:
  name: devicesetpv1
spec:
  storageClassName: ${STORAGE_CLASS}
  capacity:
    storage: ${PV_CAPACITY}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Block
  local:
    path: ${PV_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${NODE1}
---
kind: PersistentVolume
apiVersion: v1
metadata:
  name: devicesetpv2
spec:
  storageClassName: ${STORAGE_CLASS}
  capacity:
    storage: ${PV_CAPACITY}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Block
  local:
    path: ${PV_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${NODE0}
EOF
}

#------------------------------------------------------------------------------
# Phase 3: CatalogSource
#------------------------------------------------------------------------------
container_run() {
  # Prefer docker (Mac + --platform), else podman.
  if command -v docker >/dev/null 2>&1; then
    docker run --rm --platform=linux/amd64 "$@"
  elif command -v podman >/dev/null 2>&1; then
    podman run --rm --platform=linux/amd64 "$@"
  else
    die "Need docker or podman to extract ICSP/IDMS from ${OCS_REGISTRY_IMAGE}"
  fi
}

prepare_catalog() {
  [[ "${SKIP_CATALOG}" -eq 1 ]] && { log "Skipping catalog preparation"; return 0; }

  log "Disabling default redhat-operators in OperatorHub"
  run_oc patch operatorhub cluster --type=merge -p '{
  "spec": {
    "sources": [
      {"name": "redhat-operators", "disabled": true}
    ]
  }
}'

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    wait_for "default redhat-operators CatalogSource removal" 180 \
      bash -c "! oc get catalogsource ${CATALOG_SOURCE_NAME} -n openshift-marketplace >/dev/null 2>&1"
  fi

  log "Applying ICSP/IDMS from ${OCS_REGISTRY_IMAGE}"
  local mirror_applied=0
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN: would extract /icsp.yaml (and /idms.yaml if present) from ${OCS_REGISTRY_IMAGE}"
  else
    if container_run --entrypoint cat "${OCS_REGISTRY_IMAGE}" /icsp.yaml > "${WORKDIR}/icsp.yaml" 2>/dev/null; then
      oc apply -f "${WORKDIR}/icsp.yaml"
      mirror_applied=1
    else
      warn "Could not extract /icsp.yaml from registry image (may be OK on some tags)"
    fi
    if container_run --entrypoint cat "${OCS_REGISTRY_IMAGE}" /idms.yaml > "${WORKDIR}/idms.yaml" 2>/dev/null; then
      if oc apply -f "${WORKDIR}/idms.yaml"; then
        mirror_applied=1
      else
        warn "IDMS apply failed (optional on older OCP)"
      fi
    fi
  fi

  # ICSP/IDMS changes are rendered by MCO; wait so nodes can pull mirrored images.
  if [[ "${DRY_RUN}" -eq 0 && "${mirror_applied}" -eq 1 ]]; then
    log "Waiting for MachineConfigPools to finish updating after mirror config..."
    mcp_updated() {
      local not_updated
      not_updated="$(oc get mcp --no-headers 2>/dev/null | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' || true)"
      [[ -z "${not_updated}" ]]
    }
    wait_for "MachineConfigPools Updated" 2700 mcp_updated
  fi

  log "Creating custom CatalogSource ${CATALOG_SOURCE_NAME}"
  run_oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: Red Hat Operators (custom)
  publisher: Red Hat
  sourceType: grpc
  image: ${OCS_REGISTRY_IMAGE}
  updateStrategy:
    registryPoll:
      interval: 30m
EOF

  catalog_ready() {
    local state
    state="$(oc get catalogsource "${CATALOG_SOURCE_NAME}" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
    [[ "${state}" == "READY" ]]
  }
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    wait_for "CatalogSource ${CATALOG_SOURCE_NAME} READY" "${WAIT_CATALOG_TIMEOUT}" catalog_ready
  fi
}

#------------------------------------------------------------------------------
# Phase 4: ODF Subscription
#------------------------------------------------------------------------------
install_odf() {
  [[ "${SKIP_ODF}" -eq 1 ]] && { log "Skipping ODF install"; return 0; }

  log "Installing ODF operator (channel=${ODF_CHANNEL}, source=${CATALOG_SOURCE_NAME})"
  run_oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ODF_NAMESPACE}
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-data-foundation
  namespace: ${ODF_NAMESPACE}
spec:
  targetNamespaces:
    - ${ODF_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: ${ODF_NAMESPACE}
spec:
  channel: ${ODF_CHANNEL}
  installPlanApproval: Automatic
  name: ${ODF_PACKAGE}
  source: ${CATALOG_SOURCE_NAME}
  sourceNamespace: openshift-marketplace
EOF

  csv_succeeded() {
    local pending
    pending="$(oc get csv -n "${ODF_NAMESPACE}" --no-headers 2>/dev/null | awk '$NF != "Succeeded" {print $1}' || true)"
    local count
    count="$(oc get csv -n "${ODF_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${count}" -ge 1 && -z "${pending}" ]]
  }
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    wait_for "ODF CSVs Succeeded in ${ODF_NAMESPACE}" "${WAIT_CSV_TIMEOUT}" csv_succeeded
    oc get csv -n "${ODF_NAMESPACE}"
  fi
}

#------------------------------------------------------------------------------
# Phase 5: DRBD setup from operator ConfigMap
#------------------------------------------------------------------------------
setup_drbd() {
  [[ "${SKIP_DRBD}" -eq 1 ]] && { log "Skipping DRBD setup"; return 0; }

  local cm="rook-ceph-drbd-setup-script"
  drbd_cm_ready() {
    oc get configmap "${cm}" -n "${ODF_NAMESPACE}" >/dev/null 2>&1
  }
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    wait_for "ConfigMap ${cm}" "${WAIT_DRBD_CM_TIMEOUT}" drbd_cm_ready
  else
    echo "DRY-RUN: would extract ${cm} and run ./drbd-setup.sh -d ${DRBD_DEVICE}"
    return 0
  fi

  log "Extracting DRBD setup script from ConfigMap ${cm}"
  local raw script_path
  script_path="${WORKDIR}/drbd-setup.sh"
  # Prefer .data.script; fall back to .binaryData.script (base64).
  raw="$(oc get configmap "${cm}" -n "${ODF_NAMESPACE}" -o jsonpath='{.data.script}' 2>/dev/null || true)"
  if [[ -z "${raw}" ]]; then
    raw="$(oc get configmap "${cm}" -n "${ODF_NAMESPACE}" -o jsonpath='{.binaryData.script}' 2>/dev/null || true)"
    [[ -n "${raw}" ]] || die "ConfigMap ${cm} has no data.script / binaryData.script"
    printf '%s' "${raw}" | base64 -d > "${script_path}"
  else
    # Some builds store a base64 blob inside .data.script
    if [[ "${raw}" == '#!'* ]]; then
      printf '%s\n' "${raw}" > "${script_path}"
    else
      if printf '%s' "${raw}" | base64 -d > "${script_path}" 2>/dev/null && head -1 "${script_path}" | grep -q '^#!'; then
        :
      else
        printf '%s\n' "${raw}" > "${script_path}"
      fi
    fi
  fi
  chmod +x "${script_path}"

  log "Running DRBD setup: ${script_path} -d ${DRBD_DEVICE}"
  "${script_path}" -d "${DRBD_DEVICE}"
}

#------------------------------------------------------------------------------
# Phase 6: Labels
#------------------------------------------------------------------------------
label_nodes() {
  [[ "${SKIP_LABELS}" -eq 1 ]] && { log "Skipping node labels"; return 0; }

  log "Labeling worker nodes for openshift-storage"
  # TNF masters also carry the worker role.
  run_oc label nodes -l node-role.kubernetes.io/worker \
    cluster.ocs.openshift.io/openshift-storage="" --overwrite
}

#------------------------------------------------------------------------------
# Phase 7: StorageCluster
#------------------------------------------------------------------------------
create_storagecluster() {
  [[ "${SKIP_STORAGECLUSTER}" -eq 1 ]] && { log "Skipping StorageCluster"; return 0; }

  if [[ "${DRY_RUN}" -eq 0 ]] && oc get storagecluster "${STORAGECLUSTER_NAME}" -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
    log "StorageCluster ${STORAGECLUSTER_NAME} already exists"
  else
    log "Creating StorageCluster ${STORAGECLUSTER_NAME}"
    run_oc apply -f - <<EOF
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ${STORAGECLUSTER_NAME}
  namespace: ${ODF_NAMESPACE}
spec:
  flexibleScaling: true
  managedResources:
    cephCluster:
      cleanupPolicy:
        wipeDevicesFromOtherClusters: true
    cephObjectStoreUsers:
      reconcileStrategy: ignore
    cephObjectStores:
      reconcileStrategy: ignore
  monDataDirHostPath: /var/lib/rook
  multiCloudGateway:
    reconcileStrategy: ignore
  storageDeviceSets:
    - name: ${DEVICESET_NAME}
      dataPVCTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: "1"
          storageClassName: ${STORAGE_CLASS}
          volumeMode: Block
      count: 2
      replica: 1
EOF
  fi

  storagecluster_ready() {
    local phase
    phase="$(oc get storagecluster "${STORAGECLUSTER_NAME}" -n "${ODF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == "Ready" ]]
  }
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    wait_for "StorageCluster ${STORAGECLUSTER_NAME} Ready" "${WAIT_STORAGECLUSTER_TIMEOUT}" storagecluster_ready
    oc get storagecluster -n "${ODF_NAMESPACE}"
    oc get cephcluster -n "${ODF_NAMESPACE}" 2>/dev/null || true
  fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
  log "Starting ODF + DRBD setup for TNF cluster"
  preflight
  create_disks
  create_local_storage
  prepare_catalog
  install_odf
  setup_drbd
  label_nodes
  create_storagecluster
  log "Done. ODF + DRBD setup completed successfully."
  echo ""
  echo "Useful checks:"
  echo "  oc get csv -n ${ODF_NAMESPACE}"
  echo "  oc get storagecluster,cephcluster -n ${ODF_NAMESPACE}"
  echo "  oc get pods -n ${ODF_NAMESPACE}"
  echo "  oc get pv,pvc -n ${ODF_NAMESPACE}"
}

main "$@"
