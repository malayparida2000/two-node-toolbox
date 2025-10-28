# Etcd Troubleshooting Skill - Project File

## Project Overview

This project is for developing a Claude Code skill that helps troubleshoot etcd issues on two-node with fencing OpenShift clusters. The skill enables Claude to iteratively diagnose and resolve issues by leveraging Ansible to access cluster VMs directly and analyze etcd health, pacemaker status, and relevant system logs to provide diagnostic insights and troubleshooting procedures.

## Objectives

1. Provide troubleshooting expertise that validates direct Ansible access to cluster VMs
2. Gather etcd and Pacemaker status using appropriate commands
3. Collect and analyze journalctl logs for both Pacemaker and etcd services
4. Analyze the collected data to identify common issues
5. Propose and execute structured troubleshooting procedures iteratively
6. Provide actionable recommendations based on ongoing analysis

## Target Environment

- **Deployment Type**: Two-Node with Fencing (TNF) OpenShift cluster
- **Topology**: Two control plane nodes with BMC-based fencing
- **Access Method**: Ansible via inventory.ini
- **Key Components**:
  - Pacemaker (cluster resource management)
  - Corosync (cluster communication)
  - Etcd (running as Podman containers managed by Pacemaker)
  - Fencing agents (BMC/RedFish based)

## Documentation Resources

### Primary References

1. **Fencing Documentation**: `docs/fencing/README.md`
   - Overview of Two-Node with Fencing architecture
   - Etcd management by Pacemaker
   - Disruption handling (graceful and ungraceful)
   - Quorum management principles

2. **Etcd Operations Guide**: `.claude/commands/etcd/etcd-ops-guide/`
   - `clustering.md` - Cluster membership and operations
   - `configuration.md` - Configuration parameters
   - `container.md` - Container-specific operations
   - `data_corruption.md` - Data corruption detection and recovery
   - `failures.md` - Failure scenarios and handling
   - `maintenance.md` - Maintenance procedures
   - `monitoring.md` - Monitoring and metrics
   - `recovery.md` - Recovery procedures
   - `runtime-configuration.md` - Runtime configuration changes
   - `runtime-reconf-design.md` - Reconfiguration design patterns

3. **Pacemaker Documentation**: `.claude/commands/etcd/pacemaker/`
   - `podman-etcd.sh` - The resource agent managing etcd containers
   - `Pacemaker_Administration/` - Comprehensive Pacemaker administration docs
     - `administrative.rst` - Administrative tasks
     - `agents.rst` - Resource agents overview
     - `alerts.rst` - Alert configuration
     - `configuring.rst` - Cluster configuration
     - `tools.rst` - Pacemaker command-line tools
     - `troubleshooting.rst` - Pacemaker troubleshooting guide
     - `moving.rst` - Resource movement and migration
     - `options.rst` - Configuration options

4. **Remediation Tools**: `helpers/`
   - `force-new-cluster.yml` - Ansible playbook for automated cluster recovery
     - Sets force_new_cluster CIB attribute on leader node
     - Clears conflicting attributes (learner_node, standalone_node)
     - Removes follower from etcd member list
     - Creates etcd snapshots before recovery
     - Handles both scenarios: etcd running on leader, or etcd stopped on both nodes

## Technical Approach

### Phase 1: Validation

**1.1 Ansible Access Validation:**
- Verify Ansible inventory exists at `deploy/openshift-clusters/inventory.ini`
- Test SSH connectivity to cluster nodes via Ansible ping module
- Validate required tools are available on cluster nodes (pcs, podman, journalctl, crm_attribute)

**1.2 OpenShift Cluster Access Validation:**
- Attempt to run `oc version` to test direct cluster access
- If direct access fails, check for proxy configuration:
  - Look for `deploy/openshift-clusters/proxy.env` file
  - If `proxy.env` exists: source it before running `oc` commands
  - If `proxy.env` doesn't exist: warn user that cluster access requires proxy setup
- Verify cluster access by running `oc get nodes` (with proxy if needed)
- Store proxy requirement status for subsequent OpenShift API calls

**Proxy Handling Pattern:**
```bash
# Direct access attempt
oc version

# If fails, try with proxy
if [ -f deploy/openshift-clusters/proxy.env ]; then
    source deploy/openshift-clusters/proxy.env && oc version
else
    echo "WARNING: No direct cluster access and proxy.env not found"
fi
```

All subsequent `oc` commands must follow the same pattern (source proxy.env if required).

### Phase 2: Data Collection
Commands to execute via Ansible on cluster VMs.

**Important**: All commands must be executed with sudo privileges (using Ansible's `become: yes`).

**Pacemaker Status:**
```bash
sudo pcs status
sudo pcs resource status
sudo pcs constraint list
sudo crm_mon -1
```

**Etcd Container Status:**
```bash
sudo podman ps -a --filter name=etcd
sudo podman inspect etcd
sudo podman logs --tail 100 etcd
```

**Etcd Cluster Health:**
```bash
sudo podman exec etcd etcdctl member list -w table
sudo podman exec etcd etcdctl endpoint health -w table
sudo podman exec etcd etcdctl endpoint status -w table
```

**System Logs:**
```bash
sudo journalctl -u pacemaker --since "1 hour ago" -n 200
sudo journalctl -u corosync --since "1 hour ago" -n 100
sudo journalctl --grep etcd --since "1 hour ago" -n 200
```

**Cluster Attributes:**
```bash
sudo crm_attribute --query --name standalone_node
sudo crm_attribute --query --name learner_node
sudo crm_attribute --query --name force_new_cluster --lifetime reboot
```

**OpenShift Cluster Status** (requires proxy.env if configured):
```bash
# Node status
oc get nodes -o wide

# Etcd operator status
oc get co etcd -o yaml

# Etcd pods (should not exist in TNF, managed by Pacemaker)
oc get pods -n openshift-etcd

# Control plane machine config status
oc get mcp master -o yaml

# Check for degraded operators
oc get co --no-headers | grep -v "True.*False.*False"

# Etcd-related events
oc get events -n openshift-etcd --sort-by='.lastTimestamp' | tail -50
```

### Phase 3: Analysis
The command should analyze collected data for:

1. **Cluster Quorum Issues**:
   - Corosync quorum status
   - Pacemaker partition state
   - Node online/offline status

2. **Etcd Health**:
   - Member list consistency
   - Leader election status
   - Endpoint health
   - Learner vs. voting member status

3. **Resource State**:
   - Etcd resource running status
   - Failed actions in Pacemaker
   - Resource constraints violations

4. **Common Error Patterns**:
   - Certificate expiration/rotation issues
   - Network connectivity problems
   - Split-brain scenarios
   - Fencing failures
   - Data corruption indicators

5. **Cluster ID Mismatches**:
   - Detect different cluster IDs between nodes
   - Force-new-cluster flag status

6. **OpenShift Integration Issues**:
   - Etcd operator status and conditions
   - Unexpected etcd pods running in openshift-etcd namespace (should not exist in TNF)
   - Machine config pool degradation
   - Cluster operator degradation related to etcd

### Phase 4: Troubleshooting Procedure
Based on analysis, provide:

1. **Diagnosis Summary**: Clear statement of identified issues
2. **Root Cause Analysis**: Likely causes based on symptoms
3. **Step-by-Step Remediation**:
   - Ordered steps to resolve issues
   - Commands to execute
   - Expected outcomes at each step
   - Rollback procedures if available
4. **Verification Steps**: How to confirm the issue is resolved
5. **Prevention Recommendations**: How to avoid recurrence

## Key Etcd/Pacemaker Concepts

### Cluster States
- **Standalone**: Single node running as "cluster-of-one"
- **Learner**: Node rejoining cluster, not yet voting member
- **Force-new-cluster**: Flag to bootstrap new cluster from single node

### Critical Attributes (stored in CIB)
- `standalone_node` - Which node is running standalone
- `learner_node` - Which node is rejoining as learner
- `force_new_cluster` - Bootstrap flag (lifetime: reboot)
- `node_ip` - Node IP addresses
- `member_id` - Etcd member ID
- `cluster_id` - Etcd cluster ID
- `revision` - Etcd raft index

### Pacemaker Resource Agent
The `podman-etcd.sh` agent manages:
- Container lifecycle (start/stop)
- Member join/leave operations
- Certificate rotation monitoring
- Cluster ID reconciliation
- Learner promotion to voting member

### Failure Scenarios

**Graceful Disruption** (4.19+):
- Pacemaker intercepts reboot
- Removes node from etcd cluster
- Cluster continues as single node
- Node resyncs and rejoins on return

**Ungraceful Disruption** (4.20+):
- Unreachable node is fenced (powered off)
- Surviving node restarts etcd as cluster-of-one
- New cluster ID is assigned
- Failed node discards old DB and resyncs on restart

## Implementation Checklist

- [ ] Create slash command file structure
- [ ] Implement Ansible inventory validation
- [ ] Implement SSH connectivity test via Ansible
- [ ] Implement OpenShift cluster access validation
- [ ] Implement proxy.env detection and handling
- [ ] Create Ansible playbook for data collection (VM-level)
- [ ] Create oc command wrapper for proxy.env sourcing
- [ ] Implement data collection orchestration
- [ ] Create analysis functions for each component
- [ ] Implement error pattern matching
- [ ] Build troubleshooting decision tree
- [ ] Create output formatting for diagnostics
- [ ] Implement remediation procedure generator
- [ ] Add verification steps to procedures
- [ ] Test with various failure scenarios
- [ ] Test with direct cluster access (no proxy)
- [ ] Test with proxy.env required
- [ ] Test with missing proxy.env (graceful degradation)
- [ ] Document slash command usage
- [ ] Add examples of common issues

## Success Criteria

1. Command successfully validates Ansible access to cluster VMs
2. Command successfully validates OpenShift cluster access (with or without proxy)
3. Gracefully handles missing proxy.env with clear user warnings
4. Collects comprehensive etcd and Pacemaker status from VMs
5. Collects OpenShift cluster operator and node status
6. Identifies common failure patterns accurately
7. Provides clear, actionable troubleshooting procedures
8. Includes verification steps for each remediation
9. Handles edge cases gracefully (e.g., nodes unreachable, partial data collection)
10. Provides useful output even when some data collection fails

## Future Enhancements

- Interactive mode for step-by-step troubleshooting
- Automated remediation for common issues (with user confirmation)
- Historical log analysis to identify patterns over time
- Integration with OpenShift cluster-wide diagnostics
- Export diagnostics bundle for support cases
- Comparison with known-good cluster state
