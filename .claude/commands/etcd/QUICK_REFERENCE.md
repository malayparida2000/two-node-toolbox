# Etcd TNF Quick Reference Guide

**Fast troubleshooting for common etcd issues on Two-Node with Fencing clusters**

Use this guide for quick diagnosis and remediation. For detailed analysis, refer to [TROUBLESHOOTING_SKILL.md](TROUBLESHOOTING_SKILL.md).

---

## CRITICAL: Target the Correct Hosts

**Always use `cluster_vms` host group for etcd/Pacemaker commands:**

- ✓ **Correct:** `ansible cluster_vms -i inventory.ini -m shell -a "pcs status" -b`
- ✗ **Wrong:** `ansible all -i inventory.ini ...` (would include hypervisor)
- ✗ **Wrong:** `ansible hypervisor -i inventory.ini ...` (hypervisor has no etcd)

The `hypervisor` is only for VM lifecycle (virsh/kcli). All etcd operations run on `cluster_vms`.

---

## Quick Diagnostics

**Collect all diagnostics automatically:**
```bash
source .claude/commands/etcd/scripts/collect-all-diagnostics.sh
```

**Check cluster health quickly:**
```bash
# Pacemaker status (on cluster VMs)
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a "sudo pcs status" -b

# Etcd member list (on cluster VMs)
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a "sudo podman exec etcd etcdctl member list -w table" -b

# OpenShift etcd operator (if cluster access available)
oc get co etcd -o yaml | grep -A10 "status:"
```

---

## Common Issues

### 1. Etcd Start Failure: "No such device or address"

**Symptoms:**
- `pcs status` shows: `etcd start on <node> returned 'error'`
- Pacemaker logs show: `crm_attribute: Error performing operation: No such device or address`
- Member list shows member as "unstarted" with `IS_LEARNER: true`

**Root Cause:**
Stale etcd data directory with mismatched member ID. The node is trying to rejoin with old credentials that don't match the current cluster configuration.

**Diagnosis:**
```bash
# Check for member ID mismatch in logs
ansible <node> -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo journalctl -u pacemaker --since '1 hour ago' | grep -i 'member.*id'"

# Check member list from working node
ansible <working-node> -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo podman exec etcd etcdctl member list -w table"
```

**Fix:**
```bash
# Clean stale etcd data on failed node
ansible <failed-node> -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo rm -rf /var/lib/etcd/*" -b

# Cleanup Pacemaker failure state
ansible <failed-node> -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs resource cleanup etcd" -b

# Monitor recovery
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs status" -b
```

**Expected Outcome:**
- Etcd container starts on failed node
- Member joins as learner and gets promoted to voting member
- `oc get co etcd` shows Available=True within 5-10 minutes

---

### 2. Split-Brain: "master-X must force a new cluster"

**Symptoms:**
- `pcs status` shows: `etcd monitor returned 'error' (master-X must force a new cluster)`
- Both nodes have etcd running but with different cluster IDs
- CIB attributes show different `cluster_id` values

**Root Cause:**
Network partition or simultaneous failures caused both nodes to start independent etcd clusters.

**Diagnosis:**
```bash
# Check cluster IDs on both nodes
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo crm_attribute -G -n cluster_id" -b

# Check which node is standalone
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo crm_attribute -G -n standalone_node" -b
```

**Fix:**
```bash
# Identify the node with more recent data (higher revision)
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo podman exec etcd etcdctl endpoint status -w table" -b

# On the node with LESS data, clean etcd
ansible <old-node> -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs resource ban etcd <old-node> && \
   sudo rm -rf /var/lib/etcd/* && \
   sudo pcs resource clear etcd" -b

# Clear the force_new_cluster flag from CIB
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo crm_attribute -D -n force_new_cluster" -b

# Cleanup and let Pacemaker recover
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs resource cleanup etcd" -b
```

**Expected Outcome:**
- One node becomes standalone, other joins as learner
- Cluster IDs match after recovery
- Both nodes show "started" in member list

---

### 3. Quorum Loss: "no quorum"

**Symptoms:**
- `pcs status` shows: "partition WITHOUT quorum"
- Etcd resources stopped or failed
- One or both nodes may be offline

**Root Cause:**
Corosync cluster lost quorum (needs 2 nodes, has <2).

**Diagnosis:**
```bash
# Check which nodes are online
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs status | grep -A5 'Node List'" -b

# Check corosync membership
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo corosync-cmapctl | grep members" -b
```

**Fix:**

**If one node is offline:**
```bash
# Restart Pacemaker/Corosync on offline node
ansible <offline-node> -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs cluster start" -b

# Wait for quorum to be established
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs status" -b
```

**If both nodes online but no quorum (network issue):**
```bash
# Check firewall/network connectivity between nodes
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo firewall-cmd --list-all" -b

# Restart corosync cluster-wide
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs cluster stop --all && sudo pcs cluster start --all" -b
```

**Expected Outcome:**
- Both nodes show as "Online" in pcs status
- Quorum achieved
- Resources start automatically

---

### 4. Learner Stuck: Member won't promote

**Symptoms:**
- Member list shows learner with `STATUS: started, IS_LEARNER: true` for >10 minutes
- OpenShift etcd operator shows "member is a learner, waiting for promotion"
- No errors in logs, just stuck waiting

**Root Cause:**
OpenShift etcd operator learner promotion workflow stalled or conditions not met.

**Diagnosis:**
```bash
# Check learner status
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo podman exec etcd etcdctl member list -w table" -b

# Check etcd operator conditions
oc get co etcd -o yaml | grep -A20 "conditions:"

# Check for revision controller errors
oc logs -n openshift-etcd-operator deployment/etcd-operator | tail -50
```

**Fix:**
```bash
# Manually promote learner (only if stuck >15 minutes)
# First, get the learner member ID
ansible <learner-node> -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo podman exec etcd etcdctl member list -w table | grep true" -b

# Promote the learner (replace MEMBER_ID)
ansible <any-node> -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo podman exec etcd etcdctl member promote <MEMBER_ID>" -b

# Restart etcd operator to reset state machine
oc delete pod -n openshift-etcd-operator -l name=etcd-operator
```

**Expected Outcome:**
- Member shows `IS_LEARNER: false` in member list
- Etcd operator shows "2 of 2 members are available"
- Cluster becomes Available

---

### 5. Certificate Issues

**Symptoms:**
- Etcd logs show: "tls: bad certificate" or "certificate has expired"
- Etcd container fails to start with cert validation errors
- Pacemaker shows etcd start failures

**Root Cause:**
Expired or incorrect TLS certificates for etcd communication.

**Diagnosis:**
```bash
# Check certificate expiration
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo openssl x509 -in /etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-serving-$(hostname).crt -noout -dates" -b

# Check for cert errors in logs
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo podman logs etcd 2>&1 | grep -i 'certificate\|tls'" -b
```

**Fix:**
```bash
# Force certificate regeneration via machine config
oc patch etcd cluster -p='{"spec": {"forceRedeploymentReason": "cert-refresh-$(date +%s)"}}' --type=merge

# Or manually trigger cert rotation
oc delete secret -n openshift-etcd etcd-all-certs
oc delete pod -n openshift-etcd-operator -l name=etcd-operator

# Wait for operator to regenerate certs and restart etcd
oc get pods -n openshift-etcd -w
```

**Expected Outcome:**
- New certificates generated
- Etcd pods restart with valid certs
- No more TLS errors in logs

---

### 6. Pacemaker Resource Ban

**Symptoms:**
- `pcs status` shows: `etcd Stopped` on one or both nodes
- `pcs constraint list` shows location constraints preventing start
- Resource cleanup doesn't fix it

**Root Cause:**
Resource was manually banned or reached failure threshold causing automatic ban.

**Diagnosis:**
```bash
# Check for location constraints (bans)
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs constraint list --full" -b

# Check failure count
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs resource failcount show etcd" -b
```

**Fix:**
```bash
# Remove all location constraints for etcd
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs constraint list --full | grep 'location.*etcd' | cut -d' ' -f1 | xargs -I {} sudo pcs constraint remove {}" -b

# Or clear specific node ban
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs resource clear etcd" -b

# Reset failure counts
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs resource cleanup etcd" -b
```

**Expected Outcome:**
- No location constraints shown
- Etcd starts on appropriate node(s)
- Failure counts reset to 0

---

### 7. Stonith/Fencing Failures

**Symptoms:**
- `pcs status` shows: "UNCLEAN" node status
- Logs show: "fence_redfish failed" or stonith timeout
- Resources won't start due to unclean node

**Root Cause:**
Fencing agent can't reach BMC or authentication failure.

**Diagnosis:**
```bash
# Check stonith configuration
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs stonith config" -b

# Test fencing manually
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs stonith fence <node>" -b

# Check redfish connectivity
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "curl -k -u <user>:<pass> https://<bmc-ip>/redfish/v1/Systems" -b
```

**Fix:**
```bash
# Update stonith credentials if needed
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs stonith update <node>_redfish password=<new-password>" -b

# Confirm unclean node (if safe - node is really down)
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs stonith confirm <node>" -b

# Restart cluster after fencing fix
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo pcs cluster stop --all && sudo pcs cluster start --all" -b
```

**Expected Outcome:**
- Fencing test succeeds
- No UNCLEAN nodes
- Resources start normally

---

## Quick Verification Checklist

After any fix, verify:

```bash
# 1. Pacemaker cluster healthy
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a "sudo pcs status" -b
# Expected: Both nodes Online, quorum achieved, no failed actions

# 2. Etcd members healthy
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo podman exec etcd etcdctl endpoint health -w table" -b
# Expected: All endpoints healthy

# 3. Etcd member list correct
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m shell -a \
  "sudo podman exec etcd etcdctl member list -w table" -b
# Expected: 2 members, both started, both IS_LEARNER=false

# 4. OpenShift etcd operator healthy
oc get co etcd
# Expected: Available=True, Progressing=False, Degraded=False

# 5. No degraded operators
oc get co --no-headers | grep -v "True.*False.*False"
# Expected: Empty output (all operators healthy)
```

---

## When to Escalate

Use the full [TROUBLESHOOTING_SKILL.md](TROUBLESHOOTING_SKILL.md) methodology when:

- Issue doesn't match any pattern above
- Fix attempts don't resolve the problem after 2-3 iterations
- Data corruption is suspected
- Multiple components are failing simultaneously
- Need to understand deeper architectural details

## Additional Resources

- **Detailed troubleshooting**: [TROUBLESHOOTING_SKILL.md](TROUBLESHOOTING_SKILL.md)
- **Etcd operations**: Slash commands like `/etcd:etcd-ops-guide:recovery`
- **Pacemaker administration**: [pacemaker/Pacemaker_Administration/](pacemaker/Pacemaker_Administration/)
- **Diagnostic collection**: [scripts/collect-all-diagnostics.sh](scripts/collect-all-diagnostics.sh)
