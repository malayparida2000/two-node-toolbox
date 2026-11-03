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
# Libvirt <target dev=...> names for the extra disks.
# Avoid sdb/sdc: agent/dev-scripts VMs often already use those for CD-ROMs, which
# made disk_attached() falsely report "already attached" and skip the volumes.
# Guest /dev names after virtio-scsi hotplug are usually still sdb/sdc (LUN order);
# create_disks() reconciles DRBD_DEVICE/PV_PATH from lsblk by size when possible.
DEV_SMALL="${DEV_SMALL:-sdd}"
DEV_LARGE="${DEV_LARGE:-sde}"
VM0="${VM0:-}"
VM1="${VM1:-}"

ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"
STORAGE_CLASS="${STORAGE_CLASS:-local-storage}"
PV_CAPACITY="${PV_CAPACITY:-100Gi}"
# Guest paths (overridden after attach if discovery succeeds).
PV_PATH="${PV_PATH:-}"
DRBD_DEVICE="${DRBD_DEVICE:-}"

OCS_REGISTRY_IMAGE="${OCS_REGISTRY_IMAGE:-quay.io/rhceph-dev/ocs-registry:5.0.0-67.konflux}"
# Dev/konflux catalogs use package "odf-operator" with channels like stable-5.0.
# Production redhat-operators uses "openshift-data-foundation" / "stable".
ODF_CHANNEL="${ODF_CHANNEL:-}"
ODF_PACKAGE="${ODF_PACKAGE:-}"
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

# Match by volume source — target names like sdb/sdc are often taken by CD-ROMs.
disk_attached() {
  local vm="\$1" vol="\$2"
  sudo virsh dumpxml "\$vm" | grep -q "pool='\${POOL}' volume='\${vol}'"
}

attach_disk() {
  local vm="\$1" vol="\$2" dev="\$3"
  if disk_attached "\$vm" "\$vol"; then
    echo "Volume \${vol} already attached to \${vm}"
    return 0
  fi
  # --live so the running guest sees it; --persistent keeps it across reboot.
  sudo virsh attach-device "\$vm" /dev/stdin --live --persistent <<EOF
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
  sleep 8

  discover_node_names
  reconcile_guest_disk_paths
}

# Map libvirt volumes to guest /dev names via size (small=DRBD, large=PV).
reconcile_guest_disk_paths() {
  local node lsblk_out small_dev large_dev
  node="${NODE0}"

  # SIZE_SMALL/LARGE look like 10G / 256G — normalize to lsblk SIZE tokens.
  local want_small want_large
  want_small="${SIZE_SMALL}"
  want_large="${SIZE_LARGE}"

  lsblk_out="$(oc debug "node/${node}" --quiet -- chroot /host lsblk -dn -o NAME,SIZE,TYPE 2>/dev/null || true)"
  if [[ -z "${lsblk_out}" ]]; then
    warn "Could not lsblk on ${node}; using DEV_SMALL/DEV_LARGE as guest names"
    DRBD_DEVICE="${DRBD_DEVICE:-/dev/${DEV_SMALL}}"
    PV_PATH="${PV_PATH:-/dev/${DEV_LARGE}}"
    return 0
  fi

  log "lsblk on ${node}:"$'\n'"${lsblk_out}"

  # Prefer exact SIZE match for disk-type devices that are not sda (boot).
  small_dev="$(printf '%s\n' "${lsblk_out}" | awk -v s="${want_small}" '$3=="disk" && $1!="sda" && $2==s {print $1; exit}')"
  large_dev="$(printf '%s\n' "${lsblk_out}" | awk -v s="${want_large}" '$3=="disk" && $1!="sda" && $2==s {print $1; exit}')"

  if [[ -z "${small_dev}" || -z "${large_dev}" ]]; then
    # Fallback: first two non-sda disks by name order.
    local extras
    extras="$(printf '%s\n' "${lsblk_out}" | awk '$3=="disk" && $1!="sda" {print $1}')"
    small_dev="${small_dev:-$(printf '%s\n' "${extras}" | sed -n '1p')}"
    large_dev="${large_dev:-$(printf '%s\n' "${extras}" | sed -n '2p')}"
  fi

  if [[ -z "${small_dev}" || -z "${large_dev}" ]]; then
    die "Extra disks not visible in guest ${node}. Attached volumes may need a VM reboot, or set DRBD_DEVICE=/dev/... PV_PATH=/dev/..."
  fi

  DRBD_DEVICE="${DRBD_DEVICE:-/dev/${small_dev}}"
  PV_PATH="${PV_PATH:-/dev/${large_dev}}"
  log "Guest disk mapping: DRBD_DEVICE=${DRBD_DEVICE} PV_PATH=${PV_PATH}"

  local n
  for n in "${NODE0}" "${NODE1}"; do
    if oc debug "node/${n}" --quiet -- chroot /host test -b "${DRBD_DEVICE}" 2>/dev/null \
      && oc debug "node/${n}" --quiet -- chroot /host test -b "${PV_PATH}" 2>/dev/null; then
      log "Verified ${DRBD_DEVICE} and ${PV_PATH} on ${n}"
    else
      die "Missing ${DRBD_DEVICE} or ${PV_PATH} on ${n}"
    fi
  done
}

#------------------------------------------------------------------------------
# Phase 2: StorageClass + PVs
#------------------------------------------------------------------------------
create_local_storage() {
  [[ "${SKIP_STORAGE}" -eq 1 ]] && { log "Skipping StorageClass/PVs"; return 0; }
  discover_node_names
  # If disks were skipped, fall back to conventional guest names.
  DRBD_DEVICE="${DRBD_DEVICE:-/dev/sdb}"
  PV_PATH="${PV_PATH:-/dev/sdc}"
  [[ -n "${PV_PATH}" ]] || die "PV_PATH is empty"

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

  log "Applying ICSP/IDMS from ${OCS_REGISTRY_IMAGE}"
  local mirror_applied=0
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN: would extract /icsp.yaml (and /idms.yaml if present) from ${OCS_REGISTRY_IMAGE}"
  else
    # Dev/konflux catalogs point bundles at registry.redhat.io; without these
    # mirrors, OLM unpack jobs fail with unauthorized ImagePullBackOff.
    if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
      die "Need docker or podman to extract ICSP/IDMS from ${OCS_REGISTRY_IMAGE}"
    fi

    local extract_err="${WORKDIR}/mirror-extract.err"
    : > "${extract_err}"

    if container_run --entrypoint cat "${OCS_REGISTRY_IMAGE}" /idms.yaml \
         > "${WORKDIR}/idms.yaml" 2>>"${extract_err}" \
       && grep -q '^apiVersion:' "${WORKDIR}/idms.yaml"; then
      oc apply -f "${WORKDIR}/idms.yaml"
      mirror_applied=1
    else
      warn "Could not extract /idms.yaml from registry image"
    fi

    if container_run --entrypoint cat "${OCS_REGISTRY_IMAGE}" /icsp.yaml \
         > "${WORKDIR}/icsp.yaml" 2>>"${extract_err}" \
       && grep -q '^apiVersion:' "${WORKDIR}/icsp.yaml"; then
      if oc apply -f "${WORKDIR}/icsp.yaml"; then
        mirror_applied=1
      else
        warn "ICSP apply failed (IDMS alone is enough on OCP 4.13+)"
      fi
    else
      warn "Could not extract /icsp.yaml from registry image"
    fi

    if [[ "${mirror_applied}" -eq 0 ]]; then
      [[ -s "${extract_err}" ]] && cat "${extract_err}" >&2
      die "Failed to extract/apply ICSP or IDMS from ${OCS_REGISTRY_IMAGE}. Bundle pulls from registry.redhat.io will fail without mirrors. Is docker/podman running?"
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
# Resolve package/channel from the live CatalogSource packagemanifests.
# Dev catalogs (ocs-registry) ship "odf-operator" with "stable-5.0";
# production redhat-operators ships "openshift-data-foundation" with "stable".
resolve_odf_package_channel() {
  local pkg="" channel="" candidate default_channel
  local -a candidates=()

  if [[ -n "${ODF_PACKAGE}" ]]; then
    candidates+=("${ODF_PACKAGE}")
  fi
  candidates+=("odf-operator" "openshift-data-foundation")

  for candidate in "${candidates[@]}"; do
    if oc get packagemanifest "${candidate}" -n openshift-marketplace >/dev/null 2>&1; then
      # Prefer the CatalogSource we just created when multiple catalogs exist.
      local src
      src="$(oc get packagemanifest "${candidate}" -n openshift-marketplace \
        -o jsonpath='{.status.catalogSource}' 2>/dev/null || true)"
      if [[ -z "${src}" || "${src}" == "${CATALOG_SOURCE_NAME}" ]]; then
        pkg="${candidate}"
        break
      fi
      # Keep first match as fallback if catalogSource field is absent / differs.
      [[ -z "${pkg}" ]] && pkg="${candidate}"
    fi
  done

  [[ -n "${pkg}" ]] || die "No ODF packagemanifest found in openshift-marketplace (tried: ${candidates[*]}). Is CatalogSource ${CATALOG_SOURCE_NAME} READY?"

  default_channel="$(oc get packagemanifest "${pkg}" -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)"

  if [[ -n "${ODF_CHANNEL}" ]]; then
    channel="${ODF_CHANNEL}"
  elif [[ -n "${default_channel}" ]]; then
    channel="${default_channel}"
  else
    channel="stable"
  fi

  # Validate channel exists on the package when possible.
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    local channels
    channels="$(oc get packagemanifest "${pkg}" -n openshift-marketplace \
      -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
    if [[ -n "${channels}" ]] && ! printf '%s\n' "${channels}" | grep -qx "${channel}"; then
      die "Channel '${channel}' not found for package ${pkg}. Available: $(printf '%s' "${channels}" | paste -sd, -). Set ODF_CHANNEL=..."
    fi
  fi

  ODF_PACKAGE="${pkg}"
  ODF_CHANNEL="${channel}"
  log "Resolved ODF package=${ODF_PACKAGE} channel=${ODF_CHANNEL} (defaultChannel=${default_channel:-none})"
}

install_odf() {
  [[ "${SKIP_ODF}" -eq 1 ]] && { log "Skipping ODF install"; return 0; }

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    resolve_odf_package_channel
  else
    ODF_PACKAGE="${ODF_PACKAGE:-odf-operator}"
    ODF_CHANNEL="${ODF_CHANNEL:-stable-5.0}"
  fi

  log "Installing ODF operator (package=${ODF_PACKAGE}, channel=${ODF_CHANNEL}, source=${CATALOG_SOURCE_NAME})"

  # Namespace + OperatorGroup
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
EOF

  # Recreate subscription when package/channel changed — OLM often will not
  # recover from ConstraintsNotSatisfiable / ResolutionFailed otherwise.
  if [[ "${DRY_RUN}" -eq 0 ]] && oc get subscription odf-operator -n "${ODF_NAMESPACE}" >/dev/null 2>&1; then
    local cur_pkg cur_channel
    cur_pkg="$(oc get subscription odf-operator -n "${ODF_NAMESPACE}" -o jsonpath='{.spec.name}' 2>/dev/null || true)"
    cur_channel="$(oc get subscription odf-operator -n "${ODF_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || true)"
    if [[ "${cur_pkg}" != "${ODF_PACKAGE}" || "${cur_channel}" != "${ODF_CHANNEL}" ]]; then
      log "Existing subscription has package=${cur_pkg} channel=${cur_channel}; recreating for ${ODF_PACKAGE}/${ODF_CHANNEL}"
      oc delete subscription odf-operator -n "${ODF_NAMESPACE}" --wait=true
      # Stale InstallPlans / CSVs from the failed resolution can block the new one.
      oc delete installplan --all -n "${ODF_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
    fi
  fi

  run_oc apply -f - <<EOF
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
    # Fail fast only on permanent resolution errors (wrong package/channel).
    # Transient ConstraintsNotSatisfiable races are common while dependency
    # CSVs/subscriptions settle and must not abort the wait.
    local failed msg
    failed="$(oc get subscription odf-operator -n "${ODF_NAMESPACE}" \
      -o jsonpath='{range .status.conditions[?(@.type=="ResolutionFailed")]}{.status}{"|"}{.message}{"\n"}{end}' 2>/dev/null || true)"
    if [[ "${failed}" == True\|* ]]; then
      msg="${failed#True|}"
      if [[ "${msg}" == *"no operators found in package"* ]]; then
        die "Subscription resolution failed: ${msg}"
      fi
    fi

    # Require primary odf-operator CSV Succeeded, and every other CSV Succeeded.
    # Use jsonpath — tabular PHASE is not always $NF when RELEASE/REPLACES are empty.
    local primary_phase pending count
    primary_phase="$(oc get csv -n "${ODF_NAMESPACE}" -o jsonpath='{range .items[?(@.metadata.name=~"odf-operator\\..*")]}{.status.phase}{"\n"}{end}' 2>/dev/null | head -1 || true)"
    # jsonpath =~ may be unsupported on some oc versions; fall back to name scan.
    if [[ -z "${primary_phase}" ]]; then
      primary_phase="$(oc get csv -n "${ODF_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"\n"}{end}' 2>/dev/null \
        | awk -F= '$1 ~ /^odf-operator\./ {print $2; exit}' || true)"
    fi
    [[ "${primary_phase}" == "Succeeded" ]] || return 1

    pending="$(oc get csv -n "${ODF_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"\n"}{end}' 2>/dev/null \
      | awk -F= '$2 != "Succeeded" && $2 != "" {print $1"("$2")"}' || true)"
    count="$(oc get csv -n "${ODF_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
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
