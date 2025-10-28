# Etcd Troubleshooting Skill

This document defines the Claude Code skill for troubleshooting etcd issues on two-node OpenShift clusters with fencing topology. When activated, Claude becomes an expert etcd/Pacemaker troubleshooter capable of iterative diagnosis and remediation.

## Skill Overview

This skill enables Claude to:
- Validate and test access to cluster components via Ansible and OpenShift CLI
- Iteratively collect diagnostic data from Pacemaker, etcd, and OpenShift
- Analyze symptoms and identify root causes
- Propose and execute remediation steps
- Verify fixes and adjust approach based on results
- Provide comprehensive troubleshooting throughout the diagnostic process

## Step-by-Step Procedure

### 1. Validate Access

**1.1 Ansible Inventory Validation:**
- Check if `deploy/openshift-clusters/inventory.ini` exists
- Verify the inventory file has valid cluster node entries
- Test SSH connectivity to cluster nodes using Ansible ping module

**1.2 OpenShift Cluster Access Validation:**
- Test direct cluster access with `oc version`
- If direct access fails, check for `deploy/openshift-clusters/proxy.env`
- If proxy.env exists, source it before running oc commands
- Verify cluster access with `oc get nodes`
- Remember proxy requirement for all subsequent oc commands

### 2. Collect Data

Use Ansible to execute commands on cluster VMs (all commands require sudo/become):

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

**OpenShift Cluster Status** (use proxy.env if needed):
```bash
oc get nodes -o wide
oc get co etcd -o yaml
oc get pods -n openshift-etcd
oc get mcp master -o yaml
oc get co --no-headers | grep -v "True.*False.*False"
oc get events -n openshift-etcd --sort-by='.lastTimestamp' | tail -50
```

### 3. Analyze Collected Data

Look for these key issues:

**Cluster Quorum:**
- Corosync quorum status
- Pacemaker partition state
- Node online/offline status

**Etcd Health:**
- Member list consistency
- Leader election status
- Endpoint health
- Learner vs. voting member status
- Cluster ID mismatches between nodes

**Resource State:**
- Etcd resource running status
- Failed actions in Pacemaker
- Resource constraint violations

**Common Error Patterns:**
- Certificate expiration/rotation issues
- Network connectivity problems
- Split-brain scenarios
- Fencing failures
- Data corruption indicators

**OpenShift Integration:**
- Etcd operator status and conditions
- Unexpected etcd pods in openshift-etcd namespace (should not exist in TNF)
- Machine config pool degradation
- Cluster operator degradation related to etcd

### 4. Provide Troubleshooting Procedure

Based on your analysis, provide:

1. **Diagnosis Summary**: Clear statement of identified issues
2. **Root Cause Analysis**: Likely causes based on symptoms
3. **Step-by-Step Remediation**:
   - Ordered steps to resolve issues
   - Specific commands to execute
   - Expected outcomes at each step
   - Rollback procedures if available
4. **Verification Steps**: How to confirm the issue is resolved
5. **Prevention Recommendations**: How to avoid recurrence

## Key Context

### Cluster States
- **Standalone**: Single node running as "cluster-of-one"
- **Learner**: Node rejoining cluster, not yet voting member
- **Force-new-cluster**: Flag to bootstrap new cluster from single node

### Critical Attributes
- `standalone_node` - Which node is running standalone
- `learner_node` - Which node is rejoining as learner
- `force_new_cluster` - Bootstrap flag (lifetime: reboot)
- `cluster_id` - Etcd cluster ID (must match on both nodes)

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

## Reference Documentation

You have access to these slash commands for detailed information:
- `/etcd:etcd-ops-guide:clustering` - Cluster membership operations
- `/etcd:etcd-ops-guide:recovery` - Recovery procedures
- `/etcd:etcd-ops-guide:monitoring` - Monitoring and health checks
- `/etcd:etcd-ops-guide:failures` - Failure scenarios
- `/etcd:etcd-ops-guide:data_corruption` - Data corruption handling

Pacemaker documentation is available in `.claude/commands/etcd/pacemaker/` directory.

## Output Format

Provide clear, concise diagnostics with:
- Markdown formatting for readability
- Code blocks for commands
- Clear sections for diagnosis, remediation, and verification
- Actionable next steps
- Links to relevant files when referencing code or logs

## Important Notes

- Handle cases where some data collection fails gracefully
- Provide useful output even with partial data
- Warn user clearly if proxy.env is required but missing
- Always use sudo/become for commands on cluster VMs via Ansible
- Be specific about which node to run commands on when relevant
