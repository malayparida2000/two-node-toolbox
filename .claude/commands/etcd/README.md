# Etcd Troubleshooting Skill for Two-Node Clusters

This directory contains the etcd/Pacemaker troubleshooting skill for Claude Code, designed specifically for two-node OpenShift clusters with fencing topology.

## Overview

The etcd troubleshooting skill enables Claude to interactively diagnose and resolve etcd and Pacemaker issues on two-node clusters. It provides:

- Automated diagnostic data collection from cluster VMs and OpenShift
- Systematic analysis frameworks for identifying root causes
- Step-by-step remediation procedures
- Verification and prevention recommendations

## Directory Structure

```
.claude/commands/etcd/
├── README.md                           # This file
├── PROJECT.md                          # Project specification and checklist
├── TROUBLESHOOTING_SKILL.md           # Skill definition and guidelines
├── playbooks/                          # Ansible playbooks
│   ├── validate-access.yml             # Validate Ansible connectivity
│   └── collect-diagnostics.yml         # Collect VM-level diagnostics
├── scripts/                            # Helper scripts
│   ├── validate-cluster-access.sh      # Validate both Ansible and oc access
│   ├── collect-all-diagnostics.sh      # Master orchestration script
│   └── oc-wrapper.sh                   # oc wrapper with proxy.env handling
├── etcd-ops-guide/                     # Etcd operations documentation
│   ├── clustering.md
│   ├── recovery.md
│   ├── monitoring.md
│   ├── failures.md
│   └── ... (other etcd docs)
└── pacemaker/                          # Pacemaker documentation
    ├── podman-etcd.txt                 # The resource agent script (reference)
    └── Pacemaker_Administration/       # Pacemaker admin guides
```

## Quick Start

### Activating the Skill

In Claude Code, the etcd troubleshooting skill is activated by reading the TROUBLESHOOTING_SKILL.md file or referencing it in your request:

```
"Help me troubleshoot etcd issues on my two-node cluster. Use the etcd troubleshooting skill."
```

### Running Diagnostic Collection

The fastest way to gather all diagnostics:

```bash
# From repository root
./.claude/commands/etcd/scripts/collect-all-diagnostics.sh
```

This will:
1. Validate Ansible access to cluster VMs
2. Validate OpenShift cluster access (with proxy detection)
3. Collect VM-level diagnostics (Pacemaker, etcd, containers, logs)
4. Collect OpenShift cluster-level diagnostics (operators, nodes, events)
5. Generate a summary report with analysis guidance

### Individual Components

**Validate Access Only:**
```bash
./.claude/commands/etcd/scripts/validate-cluster-access.sh
```

**Collect VM-Level Diagnostics Only:**
```bash
ansible-playbook .claude/commands/etcd/playbooks/collect-diagnostics.yml \
  -i deploy/openshift-clusters/inventory.ini
```

**Use oc with Automatic Proxy Handling:**
```bash
./.claude/commands/etcd/scripts/oc-wrapper.sh get nodes
./.claude/commands/etcd/scripts/oc-wrapper.sh get co etcd
```

## Prerequisites

### Environment Requirements

- Ansible inventory at `deploy/openshift-clusters/inventory.ini`
- SSH access to cluster VMs (usually via ProxyJump through bastion)
- `oc` command in PATH
- Optional: `deploy/openshift-clusters/proxy.env` for cluster access

### Cluster Requirements

- Two-node OpenShift cluster with fencing topology
- Pacemaker and Corosync running on both nodes
- Etcd running as Podman containers managed by Pacemaker
- Stonith (fencing) configured

## Usage Patterns

### Pattern 1: Interactive Troubleshooting

When working with Claude interactively:

1. **Describe the issue** to Claude
2. Claude will **follow the decision tree** in TROUBLESHOOTING_SKILL.md
3. Claude will **collect necessary data** using playbooks/scripts
4. Claude will **analyze** the data systematically
5. Claude will **propose remediation** steps
6. You **execute or approve** the remediation
7. Claude helps **verify** the fix worked
8. Claude provides **prevention** recommendations

### Pattern 2: Automated Diagnostics

When you want to gather all data first:

1. Run `collect-all-diagnostics.sh`
2. Share the output directory with Claude
3. Claude analyzes the collected data
4. Claude provides diagnosis and remediation plan

### Pattern 3: Specific Issue Investigation

When you know the general area of the problem:

1. Tell Claude the symptoms (e.g., "etcd container won't start on node-1")
2. Claude uses targeted data collection
3. Claude applies component-specific analysis (see TROUBLESHOOTING_SKILL.md)
4. Claude provides focused remediation

## Key Features

### Proxy Handling

All scripts automatically detect and handle proxy requirements:

- Direct cluster access is tried first
- Falls back to `proxy.env` if needed
- Gracefully handles missing proxy.env with warnings
- `oc-wrapper.sh` can be used for all oc commands

### Comprehensive Data Collection

The collect-diagnostics playbook gathers:

**Pacemaker:**
- Cluster status and resource status
- Constraints and failed actions
- CIB attributes (cluster_id, standalone_node, etc.)

**Etcd:**
- Container status and logs
- Member list and endpoint health
- Cluster health and leadership info

**Logs:**
- Pacemaker, Corosync, and etcd journalctl logs
- Configurable timeframe and line limits

**OpenShift:**
- Node status and conditions
- Etcd operator status
- Cluster operator health
- Recent events

### Systematic Analysis

Claude follows structured analysis frameworks (see TROUBLESHOOTING_SKILL.md):

- Component-specific analysis functions
- Decision tree for systematic diagnosis
- Error pattern matching guidelines
- Common issue recognition

## Common Scenarios

### Scenario: Different Cluster IDs

**Symptoms:** Etcd won't start, nodes show different cluster_id in CIB attributes

**Quick Fix:**
```bash
# Use the force-new-cluster helper
ansible-playbook helpers/force-new-cluster.yml \
  -i deploy/openshift-clusters/inventory.ini
```

This designates the first node in inventory as leader and forces follower to resync.

### Scenario: Resource Failed to Start

**Symptoms:** pcs status shows "Failed Resource Actions"

**Quick Fix:**
```bash
# On cluster VMs via Ansible
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini \
  -m shell -a "pcs resource cleanup etcd" -b
```

### Scenario: Fencing Failures

**Symptoms:** Node shows UNCLEAN, fencing failed errors

**Investigation:**
```bash
# Check stonith status
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini \
  -m shell -a "pcs stonith status" -b

# Test fence agent manually
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini \
  -m shell -a "fence_redfish -a <bmc_ip> -l <user> -p <pass> -o status" -b
```

## Remediation Tools

### pcs resource cleanup

Clears failed resource states and retries operations:

```bash
sudo pcs resource cleanup etcd              # All nodes
sudo pcs resource cleanup etcd <node-name>  # Specific node
```

**When to use:**
- After fixing underlying issues
- Resource shows as failed but root cause is resolved
- After manual CIB attribute changes

### force-new-cluster Helper

Automated cluster recovery playbook at `helpers/force-new-cluster.yml`:

```bash
ansible-playbook helpers/force-new-cluster.yml \
  -i deploy/openshift-clusters/inventory.ini
```

**When to use:**
- Different etcd cluster IDs between nodes
- Etcd won't start on either node
- After ungraceful disruptions
- Manual recovery attempts failed

**See TROUBLESHOOTING_SKILL.md** for detailed documentation.

## Reference Documentation

### Etcd Operations

Slash commands for detailed etcd information:
- `/etcd:etcd-ops-guide:clustering` - Cluster membership operations
- `/etcd:etcd-ops-guide:recovery` - Recovery procedures
- `/etcd:etcd-ops-guide:monitoring` - Monitoring and health checks
- `/etcd:etcd-ops-guide:failures` - Failure scenarios
- `/etcd:etcd-ops-guide:data_corruption` - Data corruption handling

Or read files directly in `.claude/commands/etcd/etcd-ops-guide/`

### Pacemaker Administration

Documentation in `.claude/commands/etcd/pacemaker/Pacemaker_Administration/`:
- `troubleshooting.rst` - Pacemaker troubleshooting guide
- `tools.rst` - Command-line tools
- `agents.rst` - Resource agents
- `administrative.rst` - Administrative tasks

## Development and Testing

See [PROJECT.md](PROJECT.md) for:
- Implementation checklist
- Technical approach and architecture
- Testing scenarios
- Success criteria

## Environment Variables

**INVENTORY_PATH**: Override inventory location (default: `deploy/openshift-clusters/inventory.ini`)
```bash
INVENTORY_PATH=/custom/path/inventory.ini ./scripts/validate-cluster-access.sh
```

**PROXY_ENV_PATH**: Override proxy.env location (default: `deploy/openshift-clusters/proxy.env`)
```bash
PROXY_ENV_PATH=/custom/path/proxy.env ./scripts/oc-wrapper.sh get nodes
```

## Troubleshooting the Troubleshooter

If the diagnostic scripts themselves fail:

**Ansible connectivity issues:**
```bash
# Test basic connectivity
ansible cluster_vms -i deploy/openshift-clusters/inventory.ini -m ping

# Check inventory syntax
ansible-inventory -i deploy/openshift-clusters/inventory.ini --list
```

**oc access issues:**
```bash
# Test direct access
oc version

# Test with proxy
source deploy/openshift-clusters/proxy.env && oc version

# Verify KUBECONFIG
echo $KUBECONFIG
```

**Permission issues:**
```bash
# Ensure scripts are executable
chmod +x .claude/commands/etcd/scripts/*.sh
```

## Permission Configuration

To speed up diagnostics, you can configure Claude Code to automatically approve read-only operations without prompting for permission. See [PERMISSIONS.md](PERMISSIONS.md) for:

- Complete list of safe read-only commands that can be auto-approved
- Operations that always require user approval
- How to configure permissions in Claude Code
- Safety considerations and boundaries

**Quick summary of auto-approved operations:**
- File reading: `cat`, `tail`, `head`, `grep`, `ls`
- Ansible read-only: `pcs status`, `podman ps`, `etcdctl` queries, `journalctl`
- OpenShift read-only: `oc get`, `oc describe`, `oc logs`
- Validation scripts (no state changes)

**Always requires approval:**
- Ansible playbooks (including diagnostics collection)
- Pacemaker operations: `pcs resource cleanup`, restart, disable/enable
- Etcd operations: member add/remove, put/delete
- Force-new-cluster recovery
- Any system modifications

## Contributing

When adding new diagnostic capabilities:

1. Update TROUBLESHOOTING_SKILL.md with new analysis patterns
2. Add collection steps to collect-diagnostics.yml if needed
3. Update decision tree and error patterns
4. Document new remediation tools
5. Add examples to this README
6. Update PROJECT.md checklist

## License

This is part of the two-node-toolbox project. See repository root for license information.
