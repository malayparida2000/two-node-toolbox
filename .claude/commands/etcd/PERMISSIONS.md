# Etcd Troubleshooting Skill - Permission Configuration

This document defines the permission grants for the etcd troubleshooting skill to enable faster diagnostics without requiring user approval for read-only operations.

## Permission Philosophy

**Automatic (No User Approval Required):**
- Read-only operations on diagnostic data
- File reading from diagnostic output directories
- Basic Ansible fact gathering (no changes)
- OpenShift cluster status queries (read-only)

**Requires User Approval:**
- Any operation that modifies cluster state
- Running Ansible playbooks (except validation)
- Executing remediation scripts
- Pacemaker resource operations (cleanup, restart, etc.)

## Granted Permissions

### Bash Tool - Read-Only Commands

The following Bash commands are automatically approved for execution without user permission:

```
# File reading operations
Bash(cat:*)                    # Read any file
Bash(head:*)                   # Read beginning of files
Bash(tail:*)                   # Read end of files
Bash(less:*)                   # Page through files

# File searching and filtering
Bash(grep:*)                   # Search file contents
Bash(find:*)                   # Find files
Bash(ls:*)                     # List directory contents

# Diagnostic data inspection
Bash(jq:*)                     # Parse JSON output
Bash(yq:*)                     # Parse YAML output

# Git read-only operations
Bash(git log:*)                # View git history
Bash(git status:*)             # Check git status
Bash(git diff:*)               # View differences

# Ansible read-only operations
Bash(ansible cluster_vms -i * -m ping)           # Test connectivity
Bash(ansible cluster_vms -i * -m setup)          # Gather facts
Bash(ansible *_master_* -i * -m shell -a "cat *") # Read files via Ansible
Bash(ansible *_master_* -i * -m shell -a "grep *") # Search files via Ansible
Bash(ansible *_master_* -i * -m shell -a "tail *") # Read file ends via Ansible
Bash(ansible *_master_* -i * -m shell -a "pcs status*") # Read Pacemaker status
Bash(ansible *_master_* -i * -m shell -a "pcs resource status*") # Read resource status
Bash(ansible *_master_* -i * -m shell -a "podman ps*") # List containers
Bash(ansible *_master_* -i * -m shell -a "podman exec etcd etcdctl member list*") # Read member list
Bash(ansible *_master_* -i * -m shell -a "podman exec etcd etcdctl endpoint health*") # Check health
Bash(ansible *_master_* -i * -m shell -a "podman exec etcd etcdctl endpoint status*") # Check status
Bash(ansible *_master_* -i * -m shell -a "crm_attribute --query*") # Query CIB attributes
Bash(ansible *_master_* -i * -m shell -a "journalctl*") # Read system logs
Bash(ansible *_master_* -i * -m shell -a "systemctl status*") # Check service status

# OpenShift read-only operations (via oc-wrapper or with proxy sourcing)
Bash(source deploy/openshift-clusters/proxy.env && oc get*)  # Read cluster resources
Bash(source deploy/openshift-clusters/proxy.env && oc describe*) # Describe resources
Bash(source deploy/openshift-clusters/proxy.env && oc logs*) # Read pod logs
Bash(*oc-wrapper.sh get*)      # Get resources via wrapper
Bash(*oc-wrapper.sh describe*) # Describe resources via wrapper
Bash(*oc-wrapper.sh logs*)     # Read logs via wrapper
```

### Read Tool - Diagnostic Directories

The following paths are automatically approved for reading:

```
Read(/tmp/etcd-diagnostics-*/*)              # All diagnostic collection outputs
Read(/tmp/ansible-validation.log)           # Ansible validation output
Read(deploy/openshift-clusters/inventory.ini) # Inventory file (read-only)
Read(deploy/openshift-clusters/proxy.env)   # Proxy configuration (read-only)
Read(.claude/commands/etcd/**)              # Skill documentation
```

### Validation Scripts (Read-Only)

These scripts only validate access and don't modify state:

```
Bash(.claude/commands/etcd/scripts/validate-cluster-access.sh)
```

## Operations Requiring User Approval

The following operations will always prompt for user approval:

### Ansible Playbooks

```
ansible-playbook */collect-diagnostics.yml        # Requires approval (executes many commands)
ansible-playbook */validate-access.yml            # Requires approval
ansible-playbook helpers/force-new-cluster.yml    # ALWAYS requires approval (destructive)
ansible-playbook *                                # Any other playbook
```

### Orchestration Scripts

```
.claude/commands/etcd/scripts/collect-all-diagnostics.sh  # Requires approval (runs playbook)
```

### Pacemaker Operations (Write)

```
ansible * -m shell -a "pcs resource cleanup*"     # Requires approval (clears failures)
ansible * -m shell -a "pcs resource restart*"     # Requires approval (restarts resources)
ansible * -m shell -a "pcs resource disable*"     # Requires approval (disables resources)
ansible * -m shell -a "pcs resource enable*"      # Requires approval (enables resources)
ansible * -m shell -a "pcs property set*"         # Requires approval (changes config)
ansible * -m shell -a "crm_attribute --delete*"   # Requires approval (modifies CIB)
ansible * -m shell -a "crm_attribute --update*"   # Requires approval (modifies CIB)
```

### Etcd Operations (Write)

```
ansible * -m shell -a "podman exec etcd etcdctl member remove*"  # Requires approval
ansible * -m shell -a "podman exec etcd etcdctl member add*"     # Requires approval
ansible * -m shell -a "podman exec etcd etcdctl put*"            # Requires approval
ansible * -m shell -a "podman exec etcd etcdctl del*"            # Requires approval
```

### System Operations

```
ansible * -m shell -a "systemctl restart*"   # Requires approval
ansible * -m shell -a "systemctl stop*"      # Requires approval
ansible * -m shell -a "systemctl start*"     # Requires approval
ansible * -m shell -a "reboot*"              # Requires approval
```

## Usage in Claude Code

To apply these permissions, they need to be added to the Claude Code system configuration. This is typically done in one of two ways:

1. **Project-level**: In `.claude/settings.json` or project configuration
2. **User-level**: In global Claude Code settings

### Example Configuration Format

```json
{
  "autoApprove": {
    "bash": [
      "cat:*",
      "tail:*",
      "head:*",
      "grep:*",
      "ls:*",
      "git status:*",
      "git log:*",
      "ansible cluster_vms -i * -m ping",
      "source deploy/openshift-clusters/proxy.env && oc get*"
    ],
    "read": [
      "/tmp/etcd-diagnostics-*/**",
      "/tmp/ansible-validation.log",
      "deploy/openshift-clusters/inventory.ini",
      "deploy/openshift-clusters/proxy.env",
      ".claude/commands/etcd/**"
    ]
  }
}
```

## Safety Considerations

### Why These Permissions Are Safe

**Read-only Bash commands:**
- Cannot modify cluster state
- Cannot delete data
- Cannot change configurations
- Only inspect and report

**Read tool permissions:**
- Limited to diagnostic output and documentation
- No write access to sensitive files
- Inventory and proxy.env are read-only copies

**Validation scripts:**
- Only test connectivity
- Don't execute remediation actions
- Safe to run repeatedly

### What Remains Protected

**Anything that changes state:**
- Resource operations (cleanup, restart, etc.)
- CIB attribute modifications
- Playbook executions
- Service restarts
- Member additions/removals

This ensures the skill can quickly gather and analyze diagnostic information while still requiring explicit user approval for any corrective actions.

## Updating Permissions

As the skill evolves, this document should be updated to reflect:
1. New safe read-only operations that can be auto-approved
2. New operations that require user approval
3. Any changes to the permission boundaries

When in doubt, default to requiring user approval - it's better to ask permission than to execute an unexpected operation.
