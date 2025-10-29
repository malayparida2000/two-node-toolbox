# /setup Slash Command Implementation Checklist

## Command Overview
The `/setup` command guides users through first-time configuration of the two-node-toolbox repository. It helps users set up one or more of these deployment methods:
1. External host configuration
2. AWS hypervisor configuration
3. kcli installation setup
4. dev-scripts installation setup

## Command Design

### Command Syntax
- `/setup` - Interactive mode, asks user what to configure (defaults to AWS + dev-scripts)
- `/setup external` - Configure external host only
- `/setup aws` - Configure AWS hypervisor only
- `/setup kcli` - Configure kcli installation only
- `/setup dev-scripts` - Configure dev-scripts installation only
- `/setup all` - Configure all four options

### File Structure
```
.claude/commands/setup/
├── command.txt           # Main command instructions
└── IMPLEMENTATION_CHECKLIST.md  # This file
```

## Implementation Tasks

### 1. Command Instructions File Creation
- [ ] Create `.claude/commands/setup/command.txt`
- [ ] Define command behavior and flow
- [ ] Include detection logic for what's already configured
- [ ] Add links to external resources
- [ ] Include validation steps

### 2. External Host Configuration Section
Based on: `deploy/openshift-clusters/README-external-host.md`

**Prerequisites to check:**
- [ ] Ansible installed on local machine
- [ ] SSH key pair exists (`~/.ssh/id_ed25519` or similar)

**Files to configure:**
- [ ] `deploy/openshift-clusters/inventory.ini`
  - Source: `deploy/openshift-clusters/inventory.ini.sample`
  - User needs: Host IP, SSH user, sudo password (optional)

- [ ] RHSM credentials (three options):
  - Environment variables: `RHSM_ACTIVATION_KEY`, `RHSM_ORG`
  - Local file: `vars/init-host.yml.local` (from `vars/init-host.yml.sample`)
  - Command line parameters

- [ ] Link to activation key guide: https://access.redhat.com/solutions/3341191

**Collections to install:**
- [ ] Check if collections are installed
- [ ] Suggest: `ansible-galaxy collection install -r collections/requirements.yml`

**Validation:**
- [ ] Check `inventory.ini` exists and has been edited
- [ ] Check RHSM credentials are configured (env vars or file)
- [ ] Suggest running: `ansible-playbook init-host.yml -i inventory.ini`

### 3. AWS Hypervisor Configuration Section
Based on: `deploy/aws-hypervisor/README.md` and `deploy/README.md`

**Prerequisites to check:**
- [ ] AWS CLI configured (`aws configure list`)
- [ ] `AWS_PROFILE` environment variable set
- [ ] Required tools: make, aws, jq, rsync, golang, ansible
- [ ] `.ssh/config` file exists

**Files to configure:**
- [ ] `deploy/aws-hypervisor/instance.env`
  - Source: `deploy/aws-hypervisor/instance.env.template`
  - User needs to set all variables
  - Optional: `RHSM_ACTIVATION_KEY` and `RHSM_ORG` for hands-off deployment

**Validation:**
- [ ] Check `instance.env` exists
- [ ] Suggest testing: `source deploy/aws-hypervisor/instance.env`
- [ ] Provide link: https://access.redhat.com/solutions/3341191 (for activation key)

**Next steps:**
- [ ] Suggest: `cd deploy && make deploy arbiter-ipi` (or other topology)

### 4. kcli Installation Configuration Section
Based on: `deploy/openshift-clusters/README-kcli.md`

**Prerequisites to check:**
- [ ] Ansible collections installed
- [ ] Pull secret available
- [ ] SSH key exists on local machine

**Files to configure:**
- [ ] `deploy/openshift-clusters/inventory.ini`
  - Source: `deploy/openshift-clusters/inventory.ini.sample`
  - Same as external host section if not already done

- [ ] `deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json`
  - User needs pull secret from: https://cloud.redhat.com/openshift/install/pull-secret
  - For CI builds: Must include `registry.ci.openshift.org` access
  - Link: https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com

- [ ] SSH key on local machine (`~/.ssh/id_ed25519.pub`)
  - Auto-detected by deployment
  - If missing, suggest: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`

- [ ] `deploy/openshift-clusters/vars/kcli.yml` (optional, for persistent config)
  - Source: `deploy/openshift-clusters/vars/kcli.yml.template`

**Validation:**
- [ ] Check `inventory.ini` exists
- [ ] Check `pull-secret.json` exists and is valid JSON
- [ ] Check SSH key exists on local machine
- [ ] Suggest validating pull secret: `jq . < roles/kcli/kcli-install/files/pull-secret.json`

**Next steps:**
- [ ] Suggest: `ansible-playbook kcli-install.yml -i inventory.ini`

### 5. Dev-scripts Installation Configuration Section
Based on: `deploy/openshift-clusters/README.md`

**Prerequisites to check:**
- [ ] Ansible collections installed
- [ ] Pull secret available
- [ ] SSH key exists

**Files to configure:**
- [ ] `deploy/openshift-clusters/inventory.ini`
  - Source: `deploy/openshift-clusters/inventory.ini.sample`
  - Same as previous sections if not already done

- [ ] Topology config files in `deploy/openshift-clusters/roles/dev-scripts/install-dev/files/`:
  - [ ] `config_arbiter.sh` (from `config_arbiter_example.sh`)
  - [ ] `config_fencing.sh` (from `config_fencing_example.sh`)
  - User must set:
    - `CI_TOKEN` (unless using `OPENSHIFT_CI="True"`)
    - `OPENSHIFT_RELEASE_IMAGE`
  - Link for CI token: https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com

- [ ] `deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json`
  - User needs pull secret from: https://cloud.redhat.com/openshift/install/pull-secret

- [ ] SSH key configuration
  - Default: `~/.ssh/id_ed25519.pub`
  - If different, user needs to update `roles/config/tasks/main.yaml`

**Collections to install:**
- [ ] Check if collections are installed
- [ ] Suggest: `ansible-galaxy collection install -r collections/requirements.yml`

**Validation:**
- [ ] Check `inventory.ini` exists
- [ ] Check `config_arbiter.sh` exists (if arbiter topology)
- [ ] Check `config_fencing.sh` exists (if fencing topology)
- [ ] Check `pull-secret.json` exists and is valid JSON
- [ ] Check SSH key exists

**Next steps:**
- [ ] Interactive: `ansible-playbook setup.yml -i inventory.ini`
- [ ] Non-interactive arbiter: `ansible-playbook setup.yml -e "topology=arbiter" -e "interactive_mode=false" -i inventory.ini`
- [ ] Non-interactive fencing: `ansible-playbook setup.yml -e "topology=fencing" -e "interactive_mode=false" -i inventory.ini`

## Command Flow Logic

### 1. Parse Arguments
```
if arg is empty:
  ask user what to configure (default: aws + dev-scripts)
else if arg in [external, aws, kcli, dev-scripts, all]:
  configure specified option(s)
else:
  show error and usage
```

### 2. For Each Selected Configuration:
1. Explain what will be configured
2. Check prerequisites
3. Detect already configured files
4. Guide through file creation/copying
5. Provide external resource links
6. Validate configuration
7. Suggest next steps

### 3. Final Output
- Summary of what was configured
- Any warnings or missing prerequisites
- Recommended next commands to run

## External Resource Links to Include

1. **Pull Secret**: https://cloud.redhat.com/openshift/install/pull-secret
2. **CI Registry/Token**: https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com
3. **RHSM Activation Key**: https://access.redhat.com/solutions/3341191
4. **AWS CLI Setup**: https://docs.aws.amazon.com/cli/
5. **dev-scripts config reference**: https://github.com/openshift-metal3/dev-scripts/blob/master/config_example.sh

## Command Behavior Notes

- Always check what's already configured before suggesting actions
- Provide file paths as clickable VSCode links: `[filename](path/to/filename)`
- Use clear sections for each configuration type
- Show validation commands the user can run
- Include both manual steps and automated alternatives where applicable
- Make it clear which files need user-specific values vs. which can be copied as-is
- Distinguish between required and optional configurations
