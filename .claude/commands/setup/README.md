# /setup Slash Command

Interactive first-time setup assistant for the two-node-toolbox repository.

## Usage

```bash
/setup              # Interactive mode - asks what to configure (default: aws + dev-scripts)
/setup external     # Configure external host deployment only
/setup aws          # Configure AWS hypervisor deployment only
/setup kcli         # Configure kcli deployment only
/setup dev-scripts  # Configure dev-scripts deployment only
/setup all          # Configure all four deployment methods
```

## What It Does

The `/setup` command guides you through configuring the repository for first-time use by:

1. **Checking prerequisites** - Verifies required tools are installed
2. **Detecting existing config** - Checks what's already configured
3. **Guiding file setup** - Helps copy templates and edit configuration files
4. **Providing resource links** - Gives URLs where you can obtain required credentials
5. **Validating configuration** - Checks that files are properly set up
6. **Suggesting next steps** - Provides commands to run after setup

## Configuration Methods

### External Host (`/setup external`)
Configures deployment to your own RHEL 9 server (non-AWS).

**Files configured:**
- `deploy/openshift-clusters/inventory.ini` - Target host details
- RHSM credentials (env vars or config file) - For system registration
- Ansible collections installation

**Use when:** You have an existing RHEL 9 server (Beaker, lab system, etc.)

### AWS Hypervisor (`/setup aws`)
Configures automated RHEL hypervisor deployment in AWS EC2.

**Files configured:**
- `deploy/aws-hypervisor/instance.env` - AWS instance configuration

**Use when:** You want to deploy a hypervisor in AWS

### kcli Deployment (`/setup kcli`)
Configures kcli-based OpenShift deployment (fencing topology).

**Files configured:**
- `deploy/openshift-clusters/inventory.ini` - Target host details
- `deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json` - OpenShift pull secret
- `deploy/openshift-clusters/vars/kcli.yml` (optional) - Persistent kcli preferences
- SSH key validation

**Use when:** You want to deploy using the modern kcli method

### Dev-scripts Deployment (`/setup dev-scripts`)
Configures traditional dev-scripts deployment (arbiter or fencing topology).

**Files configured:**
- `deploy/openshift-clusters/inventory.ini` - Target host details
- `deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_arbiter.sh` - Arbiter config
- `deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_fencing.sh` - Fencing config
- `deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json` - OpenShift pull secret
- Ansible collections installation
- SSH key validation

**Use when:** You want to deploy using the traditional dev-scripts method

## Common Workflows

### New User with AWS Access
```bash
/setup              # Choose default: aws + dev-scripts
# Follow prompts to configure both methods
```

### New User with Existing Server
```bash
/setup external     # Configure external host first
/setup kcli         # Then configure kcli deployment
```

### Configure Everything
```bash
/setup all          # Configure all four methods
```

## External Resources You'll Need

The setup command will guide you to obtain:

1. **OpenShift Pull Secret**: https://cloud.redhat.com/openshift/install/pull-secret
2. **CI Registry Access** (for CI builds): https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com
3. **RHSM Activation Key**: https://access.redhat.com/solutions/3341191
4. **AWS CLI Setup**: https://docs.aws.amazon.com/cli/

## Files Overview

- `command.txt` - Main slash command instructions for Claude
- `IMPLEMENTATION_CHECKLIST.md` - Detailed implementation checklist
- `README.md` - This file

## See Also

- [Main README](../../../README.md) - Repository overview
- [Deploy README](../../../deploy/README.md) - Deployment command reference
- [AWS Hypervisor README](../../../deploy/aws-hypervisor/README.md) - AWS setup details
- [OpenShift Clusters README](../../../deploy/openshift-clusters/README.md) - Dev-scripts deployment
- [kcli README](../../../deploy/openshift-clusters/README-kcli.md) - kcli deployment
- [External Host README](../../../deploy/openshift-clusters/README-external-host.md) - External host setup
