#!/bin/bash
#
# DRBD Setup Script for Two-Node OpenShift Cluster
# Idempotent - can be re-run safely, skips completed steps
#
set -e

# Versions (update as needed)
DRBD_VERSION="9.2.15"
DRBD_UTILS_VERSION="9.28.0"

# DRBD Configuration
DRBD_RESOURCE_NAME="r0"
DRBD_DEVICE="/dev/drbd0"
DRBD_PORT="7788"

# Block device name on the nodes (base disk, will be partitioned)
BLOCK_DEVICE="/dev/sdc"

# Partition to use for DRBD (1 = first half, 2 = second half)
DRBD_PARTITION=2

# Initial primary node (0 = first node, 1 = second node)
PRIMARY_NODE_INDEX=0

# Namespace for DRBD auto-start DaemonSet
DAEMONSET_NAMESPACE="openshift-kmm"

# Node info (populated by detect_nodes)
NODE_0=""
NODE_1=""
NODE_0_IP=""
NODE_1_IP=""

# Actual partition used for DRBD (set by partition_disk)
DRBD_DISK_PARTITION=""

#--- Functions ---#

check_prerequisites() {
    if ! oc whoami &> /dev/null; then
        echo "Error: Not logged into OpenShift cluster"
        exit 1
    fi
    
    NODE_COUNT=$(oc get nodes --no-headers | wc -l)
    if [ "$NODE_COUNT" -ne 2 ]; then
        echo "Error: Expected 2 nodes, found $NODE_COUNT"
        exit 1
    fi
}

detect_nodes() {
    NODE_0=$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -1)
    NODE_1=$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name | tail -1)
    NODE_0_IP=$(oc get node "$NODE_0" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    NODE_1_IP=$(oc get node "$NODE_1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
}

print_config() {
    echo ""
    echo "Configuration:"
    echo "  Nodes: $NODE_0 ($NODE_0_IP), $NODE_1 ($NODE_1_IP)"
    echo "  Block Device: $BLOCK_DEVICE (partition ${DRBD_PARTITION} for DRBD)"
    echo ""
}

validate_block_device() {
    echo "==> Validating block device ${BLOCK_DEVICE}..."
    
    # Create temp files for parallel execution
    TMP_0=$(mktemp)
    TMP_1=$(mktemp)
    trap "rm -f $TMP_0 $TMP_1" RETURN
    
    # Get all device info in one call per node, run in parallel
    oc debug node/"$NODE_0" -- chroot /host bash -c "
lsblk -ndo SIZE,TYPE,RO,ROTA ${BLOCK_DEVICE} 2>/dev/null | tr -s ' '
echo '---'
lsblk -nro NAME ${BLOCK_DEVICE} 2>/dev/null
" 2>/dev/null > "$TMP_0" &
    PID_0=$!
    
    oc debug node/"$NODE_1" -- chroot /host bash -c "
lsblk -ndo SIZE,TYPE,RO,ROTA ${BLOCK_DEVICE} 2>/dev/null | tr -s ' '
echo '---'
lsblk -nro NAME ${BLOCK_DEVICE} 2>/dev/null
" 2>/dev/null > "$TMP_1" &
    PID_1=$!
    
    wait $PID_0 $PID_1
    
    # Read results from temp files
    INFO_0=$(cat "$TMP_0")
    INFO_1=$(cat "$TMP_1")
    
    # Parse node 0 info
    DEVICE_INFO_0=$(echo "$INFO_0" | head -1)
    CHILDREN_0=$(echo "$INFO_0" | sed -n '/---/,$p' | tail -n +2 | wc -l)
    HAS_DRBD_0=$(echo "$INFO_0" | grep -c drbd || true)
    
    # Parse node 1 info
    DEVICE_INFO_1=$(echo "$INFO_1" | head -1)
    CHILDREN_1=$(echo "$INFO_1" | sed -n '/---/,$p' | tail -n +2 | wc -l)
    HAS_DRBD_1=$(echo "$INFO_1" | grep -c drbd || true)
    
    # Check device exists
    if [ -z "$DEVICE_INFO_0" ]; then
        echo "Error: $BLOCK_DEVICE not found on $NODE_0"
        exit 1
    fi
    if [ -z "$DEVICE_INFO_1" ]; then
        echo "Error: $BLOCK_DEVICE not found on $NODE_1"
        exit 1
    fi
    
    # Parse values: SIZE TYPE RO ROTA
    SIZE_0=$(echo "$DEVICE_INFO_0" | awk '{print $1}')
    TYPE_0=$(echo "$DEVICE_INFO_0" | awk '{print $2}')
    RO_0=$(echo "$DEVICE_INFO_0" | awk '{print $3}')
    ROTA_0=$(echo "$DEVICE_INFO_0" | awk '{print $4}')
    
    SIZE_1=$(echo "$DEVICE_INFO_1" | awk '{print $1}')
    TYPE_1=$(echo "$DEVICE_INFO_1" | awk '{print $2}')
    RO_1=$(echo "$DEVICE_INFO_1" | awk '{print $3}')
    ROTA_1=$(echo "$DEVICE_INFO_1" | awk '{print $4}')
    
    # Validate
    if [ "$TYPE_0" != "disk" ]; then
        echo "Error: $BLOCK_DEVICE on $NODE_0 is type '$TYPE_0', expected 'disk'"; exit 1
    fi
    if [ "$TYPE_1" != "disk" ]; then
        echo "Error: $BLOCK_DEVICE on $NODE_1 is type '$TYPE_1', expected 'disk'"; exit 1
    fi
    if [ "$RO_0" != "0" ]; then
        echo "Error: $BLOCK_DEVICE on $NODE_0 is read-only"; exit 1
    fi
    if [ "$RO_1" != "0" ]; then
        echo "Error: $BLOCK_DEVICE on $NODE_1 is read-only"; exit 1
    fi
    if [ "$SIZE_0" != "$SIZE_1" ]; then
        echo "Error: Size mismatch - $NODE_0: $SIZE_0, $NODE_1: $SIZE_1"; exit 1
    fi
    
    # Warnings
    [ "$ROTA_0" != "0" ] && echo "Warning: $BLOCK_DEVICE on $NODE_0 is rotational (HDD)"
    [ "$ROTA_1" != "0" ] && echo "Warning: $BLOCK_DEVICE on $NODE_1 is rotational (HDD)"
    
    echo "  $NODE_0: $SIZE_0, type=$TYPE_0, rota=$ROTA_0"
    echo "  $NODE_1: $SIZE_1, type=$TYPE_1, rota=$ROTA_1"
    echo "Block device validated"
}

partition_disk() {
    echo "==> Checking partitions on ${BLOCK_DEVICE}..."
    
    # Create temp files for parallel execution
    TMP_0=$(mktemp)
    TMP_1=$(mktemp)
    trap "rm -f $TMP_0 $TMP_1" RETURN
    
    # Get partition info from both nodes in parallel
    # Only count TYPE=part to exclude drbd devices
    oc debug node/"$NODE_0" -- chroot /host bash -c "
PARTS=\$(lsblk -nro NAME,TYPE ${BLOCK_DEVICE} 2>/dev/null | grep ' part\$' | awk '{print \$1}')
COUNT=\$(echo \"\$PARTS\" | grep -c . || echo 0)
SECOND=\$(echo \"\$PARTS\" | sed -n '2p')
if [ -n \"\$SECOND\" ]; then
    SIZE=\$(lsblk -ndo SIZE /dev/\${SECOND} 2>/dev/null)
else
    SIZE=''
fi
echo \"\${COUNT}|\${SECOND}|\${SIZE}\"
" 2>/dev/null > "$TMP_0" &
    PID_0=$!
    
    oc debug node/"$NODE_1" -- chroot /host bash -c "
PARTS=\$(lsblk -nro NAME,TYPE ${BLOCK_DEVICE} 2>/dev/null | grep ' part\$' | awk '{print \$1}')
COUNT=\$(echo \"\$PARTS\" | grep -c . || echo 0)
SECOND=\$(echo \"\$PARTS\" | sed -n '2p')
if [ -n \"\$SECOND\" ]; then
    SIZE=\$(lsblk -ndo SIZE /dev/\${SECOND} 2>/dev/null)
else
    SIZE=''
fi
echo \"\${COUNT}|\${SECOND}|\${SIZE}\"
" 2>/dev/null > "$TMP_1" &
    PID_1=$!
    
    wait $PID_0 $PID_1
    
    # Read results from temp files
    PART_INFO_0=$(tail -1 "$TMP_0" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    PART_INFO_1=$(tail -1 "$TMP_1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    COUNT_0=$(echo "$PART_INFO_0" | cut -d'|' -f1)
    SECOND_0=$(echo "$PART_INFO_0" | cut -d'|' -f2)
    SIZE_0=$(echo "$PART_INFO_0" | cut -d'|' -f3)
    COUNT_1=$(echo "$PART_INFO_1" | cut -d'|' -f1)
    SECOND_1=$(echo "$PART_INFO_1" | cut -d'|' -f2)
    SIZE_1=$(echo "$PART_INFO_1" | cut -d'|' -f3)
    
    # Handle empty counts
    [ -z "$COUNT_0" ] && COUNT_0=0
    [ -z "$COUNT_1" ] && COUNT_1=0
    
    if [ "$COUNT_0" -eq 0 ]; then
        echo "  $NODE_0: No partitions"
    else
        echo "  $NODE_0: $COUNT_0 partition(s), 2nd partition: $SECOND_0 ($SIZE_0)"
    fi
    if [ "$COUNT_1" -eq 0 ]; then
        echo "  $NODE_1: No partitions"
    else
        echo "  $NODE_1: $COUNT_1 partition(s), 2nd partition: $SECOND_1 ($SIZE_1)"
    fi
    
    # Case 1: Both have exactly 2 partitions with matching 2nd partition names and sizes
    if [ "$COUNT_0" -eq 2 ] && [ "$COUNT_1" -eq 2 ]; then
        if [ "$SECOND_0" != "$SECOND_1" ] || [ -z "$SECOND_0" ]; then
            echo "Error: 2nd partition names don't match ($SECOND_0 vs $SECOND_1)"
            exit 1
        fi
        if [ "$SIZE_0" != "$SIZE_1" ]; then
            echo "Error: 2nd partition sizes don't match ($SIZE_0 vs $SIZE_1)"
            exit 1
        fi
        DRBD_DISK_PARTITION="/dev/${SECOND_0}"
        echo "==> Using existing partition $DRBD_DISK_PARTITION for DRBD"
        return
    fi
    
    # Case 2: No partitions on both nodes - create them
    if [ "$COUNT_0" -eq 0 ] && [ "$COUNT_1" -eq 0 ]; then
        echo "==> Partitioning ${BLOCK_DEVICE} on both nodes (50/50 split)..."
        
        for node in "$NODE_0" "$NODE_1"; do
            oc debug node/"$node" -- chroot /host bash -c "
SECTORS=\$(blockdev --getsz ${BLOCK_DEVICE})
HALF=\$((SECTORS / 2))
sgdisk -Z ${BLOCK_DEVICE}
sgdisk -n 1:2048:+\${HALF}s -t 1:8300 ${BLOCK_DEVICE}
sgdisk -n 2:0:0 -t 2:8300 ${BLOCK_DEVICE}
udevadm settle
lsblk ${BLOCK_DEVICE}
" 2>/dev/null &
        done
        wait
        
        DRBD_DISK_PARTITION="${BLOCK_DEVICE}${DRBD_PARTITION}"
        echo "Partitioning complete. Using $DRBD_DISK_PARTITION for DRBD"
        return
    fi
    
    # Case 3: More than 2 partitions or mismatched counts - error
    echo "Error: Unexpected partition layout."
    echo "  Expected: 0 partitions (will create) or exactly 2 partitions on both nodes"
    echo "  Found: $NODE_0 has $COUNT_0, $NODE_1 has $COUNT_1"
    exit 1
}

setup_kmm_operator() {
    if oc get csv -n openshift-kmm 2>/dev/null | grep -q Succeeded; then
        echo "==> KMM Operator already installed, skipping"
        return
    fi

    echo "==> Installing KMM Operator..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kmm
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kernel-module-management
  namespace: openshift-kmm
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kernel-module-management
  namespace: openshift-kmm
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kernel-module-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    echo "Waiting for KMM operator..."
    for i in {1..60}; do
        if oc get csv -n openshift-kmm 2>/dev/null | grep -q Succeeded; then
            echo "KMM ready"
            break
        fi
        if [ $i -eq 60 ]; then
            echo "Error: KMM operator failed to become ready after 5 minutes"
            return 1
        fi
        sleep 5
    done
}

setup_image_registry() {
    if oc get deployment image-registry -n openshift-image-registry &>/dev/null && \
       oc get deployment image-registry -n openshift-image-registry -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q "1"; then
        echo "==> Image registry already available, skipping"
        return
    fi

    echo "==> Setting up image registry..."
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
        --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}' 2>/dev/null || true
    oc wait --for=condition=available --timeout=300s deployment/image-registry -n openshift-image-registry
    echo "Image registry ready"
}

create_drbd_module() {
    if oc get module drbd-kmod -n openshift-kmm &>/dev/null; then
        echo "==> DRBD Module CR already exists, skipping"
        return
    fi

    echo "==> Creating DRBD module..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: drbd-kmod-dockerfile
  namespace: openshift-kmm
data:
  dockerfile: |
    ARG DTK_AUTO
    ARG KERNEL_FULL_VERSION
    FROM \${DTK_AUTO} AS builder
    ARG KERNEL_FULL_VERSION
    WORKDIR /tmp/drbd_build
    RUN wget https://pkg.linbit.com//downloads/drbd/9/drbd-${DRBD_VERSION}.tar.gz && tar -xvzf drbd-${DRBD_VERSION}.tar.gz
    WORKDIR /tmp/drbd_build/drbd-${DRBD_VERSION}
    RUN make KVER=\${KERNEL_FULL_VERSION} -j\$(nproc)
    RUN mkdir -p /install/lib/modules/\${KERNEL_FULL_VERSION}/extra
    RUN cp drbd/build-current/drbd.ko drbd/build-current/drbd_transport_tcp.ko /install/lib/modules/\${KERNEL_FULL_VERSION}/extra/
    RUN depmod -b /install \${KERNEL_FULL_VERSION}
    FROM registry.redhat.io/ubi9/ubi-minimal
    ARG KERNEL_FULL_VERSION
    COPY --from=builder /install/lib/modules/ /opt/lib/modules/
EOF

    cat <<EOF | oc apply -f -
apiVersion: kmm.sigs.x-k8s.io/v1beta1
kind: Module
metadata:
  name: drbd-kmod
  namespace: openshift-kmm
spec:
  moduleLoader:
    container:
      modprobe:
        moduleName: drbd_transport_tcp
        dirName: /opt
      kernelMappings:
        - regexp: '^.*\.x86_64$'
          containerImage: "image-registry.openshift-image-registry.svc:5000/openshift-kmm/drbd_compat_kmod:\${KERNEL_FULL_VERSION}"
          build:
            dockerfileConfigMap:
              name: drbd-kmod-dockerfile
  selector: {}
EOF
    echo "DRBD Module CR created"
}

wait_for_modules() {
    # Check if both drbd and drbd_transport_tcp modules loaded on both nodes
    if oc debug node/"$NODE_0" -- chroot /host lsmod 2>/dev/null | grep -q "^drbd " && \
       oc debug node/"$NODE_0" -- chroot /host lsmod 2>/dev/null | grep -q drbd_transport_tcp && \
       oc debug node/"$NODE_1" -- chroot /host lsmod 2>/dev/null | grep -q "^drbd " && \
       oc debug node/"$NODE_1" -- chroot /host lsmod 2>/dev/null | grep -q drbd_transport_tcp; then
        echo "==> DRBD modules already loaded on both nodes, skipping"
        return
    fi

    echo "==> Waiting for modules to load..."
    for i in {1..60}; do
        if oc debug node/"$NODE_0" -- chroot /host lsmod 2>/dev/null | grep -q "^drbd " && \
           oc debug node/"$NODE_0" -- chroot /host lsmod 2>/dev/null | grep -q drbd_transport_tcp && \
           oc debug node/"$NODE_1" -- chroot /host lsmod 2>/dev/null | grep -q "^drbd " && \
           oc debug node/"$NODE_1" -- chroot /host lsmod 2>/dev/null | grep -q drbd_transport_tcp; then
            echo "Modules loaded (drbd + drbd_transport_tcp)"
            break
        fi
        if [ $i -eq 60 ]; then
            echo "Error: DRBD modules failed to load on both nodes after 10 minutes"
            return 1
        fi
        sleep 10
    done
}

install_drbd_utils() {
    # Check if already installed on both nodes
    if oc debug node/"$NODE_0" -- chroot /host test -x /usr/local/sbin/drbdadm 2>/dev/null && \
       oc debug node/"$NODE_1" -- chroot /host test -x /usr/local/sbin/drbdadm 2>/dev/null; then
        echo "==> DRBD utilities already installed on both nodes, skipping"
        return
    fi

    echo "==> Installing DRBD utilities..."
    for node in "$NODE_0" "$NODE_1"; do
        oc debug node/"$node" -- chroot /host bash -c "
test -x /usr/local/sbin/drbdadm && exit 0
mkdir -p /usr/local/sbin && cd /tmp && rm -rf drbd-extract && mkdir drbd-extract && cd drbd-extract
curl -sLO https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/d/drbd-utils-${DRBD_UTILS_VERSION}-1.el9.x86_64.rpm
rpm2cpio drbd-utils-${DRBD_UTILS_VERSION}-1.el9.x86_64.rpm | cpio -idmu 2>/dev/null
cp ./usr/sbin/drbdadm ./usr/sbin/drbdsetup ./usr/sbin/drbdmeta /usr/local/sbin/
chmod +x /usr/local/sbin/drbd* && cd /tmp && rm -rf drbd-extract
" 2>/dev/null
    done
    echo "Utilities installed"
}

configure_drbd() {
    # DRBD_DISK_PARTITION is set by partition_disk function
    
    # Check if DRBD is already up on both nodes
    if oc debug node/"$NODE_0" -- chroot /host /usr/local/sbin/drbdadm status ${DRBD_RESOURCE_NAME} 2>/dev/null | grep -q "role:" && \
       oc debug node/"$NODE_1" -- chroot /host /usr/local/sbin/drbdadm status ${DRBD_RESOURCE_NAME} 2>/dev/null | grep -q "role:"; then
        echo "==> DRBD already configured and running, skipping"
        return
    fi

    echo "==> Configuring DRBD on ${DRBD_DISK_PARTITION}..."
    DRBD_CONFIG="global { usage-count no; }
common {
    net { protocol C; after-sb-0pri discard-zero-changes; after-sb-1pri discard-secondary; }
    disk { on-io-error pass_on; }
    options { on-no-data-accessible suspend-io; }
}
resource ${DRBD_RESOURCE_NAME} {
    device ${DRBD_DEVICE}; disk ${DRBD_DISK_PARTITION}; meta-disk internal;
    on ${NODE_0} { address ${NODE_0_IP}:${DRBD_PORT}; node-id 0; }
    on ${NODE_1} { address ${NODE_1_IP}:${DRBD_PORT}; node-id 1; }
}"

    DRBD_CONF_B64=$(echo "$DRBD_CONFIG" | base64 -w0)

    for node in "$NODE_0" "$NODE_1"; do
        oc debug node/"$node" -- chroot /host bash -c "
mkdir -p /etc/drbd.d /var/lib/drbd
echo '$DRBD_CONF_B64' | base64 -d > /etc/drbd.d/${DRBD_RESOURCE_NAME}.res
echo 'include \"/etc/drbd.d/*.res\";' > /etc/drbd.conf
if ! /usr/local/sbin/drbdadm status ${DRBD_RESOURCE_NAME} &>/dev/null; then
    /usr/local/sbin/drbdmeta 0 v09 ${DRBD_DISK_PARTITION} internal create-md 1 --force
    /usr/local/sbin/drbdadm up ${DRBD_RESOURCE_NAME}
fi
" 2>/dev/null &
    done
    wait
    echo "DRBD configured and started"
}

sync_drbd() {
    # Determine primary node based on config
    if [ "$PRIMARY_NODE_INDEX" -eq 0 ]; then
        PRIMARY_NODE="$NODE_0"
    else
        PRIMARY_NODE="$NODE_1"
    fi

    # Check if already synced (both UpToDate)
    if oc debug node/"$PRIMARY_NODE" -- chroot /host /usr/local/sbin/drbdadm status ${DRBD_RESOURCE_NAME} 2>/dev/null | grep -q "disk:UpToDate" && \
       oc debug node/"$PRIMARY_NODE" -- chroot /host /usr/local/sbin/drbdadm status ${DRBD_RESOURCE_NAME} 2>/dev/null | grep -q "peer-disk:UpToDate"; then
        echo "==> DRBD already synced, skipping"
        return
    fi

    echo "==> Promoting $PRIMARY_NODE to primary and starting sync..."
    oc debug node/"$PRIMARY_NODE" -- chroot /host /usr/local/sbin/drbdadm primary --force ${DRBD_RESOURCE_NAME} 2>/dev/null || true

    echo "==> Waiting for sync to complete..."
    for i in {1..120}; do
        STATUS=$(oc debug node/"$PRIMARY_NODE" -- chroot /host /usr/local/sbin/drbdadm status ${DRBD_RESOURCE_NAME} 2>/dev/null)
        if echo "$STATUS" | grep -q "peer-disk:UpToDate"; then
            echo "Sync complete!"
            echo "$STATUS"
            break
        fi
        PROGRESS=$(echo "$STATUS" | grep -o 'done:[0-9.]*' | head -1 | cut -d: -f2)
        if [ -n "$PROGRESS" ]; then
            echo "Syncing: ${PROGRESS}%"
        fi
        if [ $i -eq 120 ]; then
            echo "Error: DRBD sync failed to complete after 60 minutes"
            echo "Current status:"
            echo "$STATUS"
            return 1
        fi
        sleep 30
    done
}

setup_drbd_autostart() {
    # Check if DaemonSet already exists
    if oc get daemonset drbd-autostart -n ${DAEMONSET_NAMESPACE} &>/dev/null; then
        echo "==> DRBD auto-start DaemonSet already exists, skipping"
        return
    fi

    echo "==> Creating DRBD auto-start DaemonSet..."
    
    # Create namespace if it doesn't exist (idempotent)
    oc create namespace ${DAEMONSET_NAMESPACE} --dry-run=client -o yaml | oc apply -f - 2>/dev/null
    
    # Create ServiceAccount for privileged access (idempotent)
    oc create serviceaccount drbd-autostart -n ${DAEMONSET_NAMESPACE} --dry-run=client -o yaml | oc apply -f - 2>/dev/null
    
    # Grant privileged SCC to the service account
    oc adm policy add-scc-to-user privileged -z drbd-autostart -n ${DAEMONSET_NAMESPACE}
    
    # Create ConfigMap with startup script (using variable expansion)
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: drbd-autostart-script
  namespace: ${DAEMONSET_NAMESPACE}
data:
  start.sh: |
    #!/bin/bash
    set -e
    
    # Wait for DRBD kernel modules to be loaded (up to 5 minutes)
    echo "Waiting for DRBD kernel modules..."
    for i in {1..60}; do
        if chroot /host lsmod | grep -q "^drbd "; then
            echo "DRBD modules loaded"
            break
        fi
        if [ $i -eq 60 ]; then
            echo "Error: DRBD module not loaded after 5 minutes"
            exit 1
        fi
        sleep 5
    done
    
    # Check if DRBD is already up, if not bring it up
    if chroot /host /usr/local/sbin/drbdadm status ${DRBD_RESOURCE_NAME} &>/dev/null; then
        echo "DRBD resource ${DRBD_RESOURCE_NAME} is already up"
    else
        echo "Starting DRBD resource ${DRBD_RESOURCE_NAME}..."
        chroot /host /usr/local/sbin/drbdadm up ${DRBD_RESOURCE_NAME} || true
    fi
    
    chroot /host /usr/local/sbin/drbdadm status ${DRBD_RESOURCE_NAME}
    
    while true; do
        sleep 3600
    done
EOF

    # Create DaemonSet
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: drbd-autostart
  namespace: ${DAEMONSET_NAMESPACE}
  labels:
    app: drbd-autostart
spec:
  selector:
    matchLabels:
      app: drbd-autostart
  template:
    metadata:
      labels:
        app: drbd-autostart
    spec:
      serviceAccountName: drbd-autostart
      hostNetwork: true
      hostPID: true
      containers:
      - name: drbd-starter
        image: registry.redhat.io/ubi9/ubi-minimal:latest
        command: ["/bin/bash", "/scripts/start.sh"]
        securityContext:
          privileged: true
          capabilities:
            add:
            - SYS_ADMIN
            - SYS_MODULE
            - NET_ADMIN
        volumeMounts:
        - name: host-root
          mountPath: /host
          readOnly: false
        - name: scripts
          mountPath: /scripts
          readOnly: true
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
      volumes:
      - name: host-root
        hostPath:
          path: /
          type: Directory
      - name: scripts
        configMap:
          name: drbd-autostart-script
          defaultMode: 0755
      tolerations:
      - operator: Exists
        effect: NoSchedule
      - operator: Exists
        effect: NoExecute
EOF

    echo "Waiting for DaemonSet pods to be ready..."
    for i in {1..60}; do
        READY_COUNT=$(($(oc get daemonset drbd-autostart -n ${DAEMONSET_NAMESPACE} -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")))
        [ "$READY_COUNT" -eq 2 ] && echo "DRBD auto-start DaemonSet created successfully" && break
        
        if [ $i -eq 60 ]; then
            echo "Error: DaemonSet pods failed to start after 5 minutes."
            echo "  Check with: oc get daemonset drbd-autostart -n ${DAEMONSET_NAMESPACE}"
            echo "  Check pod logs: oc logs -n ${DAEMONSET_NAMESPACE} -l app=drbd-autostart"
            return 1
        fi
        
        sleep 5
    done
}

print_summary() {
    if [ "$PRIMARY_NODE_INDEX" -eq 0 ]; then
        PRIMARY="$NODE_0"; SECONDARY="$NODE_1"
    else
        PRIMARY="$NODE_1"; SECONDARY="$NODE_0"
    fi
    echo ""
    echo "=== DRBD Setup Complete ==="
    echo "Primary: $PRIMARY, Secondary: $SECONDARY"
    echo "Device: $DRBD_DEVICE, Disk: $DRBD_DISK_PARTITION"
}

#--- Main ---#

main() {
    check_prerequisites
    detect_nodes
    print_config
    validate_block_device
    partition_disk
    setup_kmm_operator
    setup_image_registry
    create_drbd_module
    wait_for_modules
    install_drbd_utils
    configure_drbd
    sync_drbd
    setup_drbd_autostart
    print_summary
}

main "$@"
