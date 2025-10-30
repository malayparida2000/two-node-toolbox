You are helping a user set up the two-node-toolbox repository for the first time. Guide them through the configuration process step by step.

## Command Arguments

The user may specify what they want to configure:
- `/setup` or `/setup` with no args: Ask what to configure (default: aws + dev-scripts)
- `/setup external`: Configure external host only
- `/setup aws`: Configure AWS hypervisor only
- `/setup kcli`: Configure kcli installation only
- `/setup dev-scripts`: Configure dev-scripts installation only
- `/setup all`: Configure all four options

## Your Task

Based on the argument provided (or user's interactive choice), guide them through configuring the selected deployment method(s). For each selected method:

1. **Check current state** - Verify what's already configured
2. **Explain prerequisites** - Check if required tools/files are present
3. **Guide file setup** - Help copy templates and configure files (ONE STEP AT A TIME)
4. **Provide resource links** - Give URLs for external resources they need
5. **Validate configuration** - Check if files are properly set up
6. **Suggest next steps** - Provide commands to run next

## Configuration Sections

### External Host Configuration

**Purpose**: Set up to deploy on your own RHEL 9 server (not AWS)

**Prerequisites to check:**
- Check if ansible is installed: `which ansible-playbook`
- Check if SSH key exists: Look for `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`

**Files to configure:**

1. **Inventory file**: [deploy/openshift-clusters/inventory.ini](deploy/openshift-clusters/inventory.ini)
   - Template: [deploy/openshift-clusters/inventory.ini.sample](deploy/openshift-clusters/inventory.ini.sample)
   - Check if it exists and has been edited (differs from sample)
   - User needs to provide: host IP, SSH user, optional sudo password
   - Suggest copying: `cp deploy/openshift-clusters/inventory.ini.sample deploy/openshift-clusters/inventory.ini`

2. **RHSM credentials** (3 options - user picks one):
   - **Option A (Recommended)**: Environment variables
     - `export RHSM_ACTIVATION_KEY="your-key"`
     - `export RHSM_ORG="your-org-id"`
     - Guide: https://access.redhat.com/solutions/3341191

   - **Option B**: Local config file [vars/init-host.yml.local](vars/init-host.yml.local)
     - Template: [vars/init-host.yml.sample](vars/init-host.yml.sample)
     - Check if exists
     - Suggest copying: `cp vars/init-host.yml.sample vars/init-host.yml.local`

   - **Option C**: Command line (they'll add when running playbook)

3. **Ansible collections**:
   - Check if [collections/requirements.yml](collections/requirements.yml) exists
   - Suggest: `ansible-galaxy collection install -r collections/requirements.yml`

**Validation:**
- Verify [deploy/openshift-clusters/inventory.ini](deploy/openshift-clusters/inventory.ini) exists
- Check if RHSM credentials are configured (env vars or file)
- Verify SSH key exists

**Next steps:**
- Run: `ansible-playbook deploy/openshift-clusters/init-host.yml -i deploy/openshift-clusters/inventory.ini`

---

### AWS Hypervisor Configuration

**Purpose**: Automate RHEL hypervisor deployment in AWS EC2

**Prerequisites to check:**
- AWS CLI configured: `aws configure list` should show profile and credentials
- Check if `AWS_PROFILE` environment variable is set
- Required tools: make, aws, jq, rsync, golang, ansible
- Check if `~/.ssh/config` file exists

**Files to configure:**

1. **Instance environment**: [deploy/aws-hypervisor/instance.env](deploy/aws-hypervisor/instance.env)
   - Template: [deploy/aws-hypervisor/instance.env.template](deploy/aws-hypervisor/instance.env.template)
   - Check if it exists
   - User must edit ALL variables with their specific values
   - Optional: Set `RHSM_ACTIVATION_KEY` and `RHSM_ORG` for hands-off deployment
     - Guide: https://access.redhat.com/solutions/3341191
   - Suggest copying: `cp deploy/aws-hypervisor/instance.env.template deploy/aws-hypervisor/instance.env`

**Validation:**
- Verify [deploy/aws-hypervisor/instance.env](deploy/aws-hypervisor/instance.env) exists
- Test by sourcing: `source deploy/aws-hypervisor/instance.env` (should not error)

**Next steps:**
- Quick deploy: `cd deploy && make deploy arbiter-ipi`
- Or see all options: `cd deploy && make help`

---

### kcli Installation Configuration

**Purpose**: Deploy OpenShift using kcli virtualization tool (fencing topology)

**Prerequisites to check:**
- Ansible collections installed
- SSH key exists on local machine: `~/.ssh/id_ed25519.pub`

**Files to configure:**

1. **Inventory file**: [deploy/openshift-clusters/inventory.ini](deploy/openshift-clusters/inventory.ini)
   - Same as external host section (skip if already configured)

2. **Pull secret**: [deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json](deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json)
   - **NOTE**: This is the same pull secret used by dev-scripts
   - Check if file exists here OR at [deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json)
   - If it exists in either location, offer to copy it to the other location
   - If it doesn't exist anywhere:
     - User gets pull secret from: https://cloud.redhat.com/openshift/install/pull-secret
     - **For CI builds**: Must include `registry.ci.openshift.org` access
       - Get CI access: https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com
       - Login → Click name → "Copy login command" → "Display Token"
     - Suggest creating file and pasting content

3. **SSH key on local machine**:
   - Check if `~/.ssh/id_ed25519.pub` exists
   - If not: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`

4. **Optional persistent config**: [deploy/openshift-clusters/vars/kcli.yml](deploy/openshift-clusters/vars/kcli.yml)
   - Template: [deploy/openshift-clusters/vars/kcli.yml.template](deploy/openshift-clusters/vars/kcli.yml.template)
   - Check if exists
   - For setting preferred defaults (cluster name, resources, etc.)
   - Suggest copying: `cp deploy/openshift-clusters/vars/kcli.yml.template deploy/openshift-clusters/vars/kcli.yml`

**Validation:**
- Verify [inventory.ini](deploy/openshift-clusters/inventory.ini) exists
- Verify [pull-secret.json](deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json) exists
- Validate pull secret is valid JSON: `jq . < deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json`
- Check for CI registry access (if needed): `jq '.auths | has("registry.ci.openshift.org")' < deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json`
- Verify SSH key exists

**Next steps:**
- Run: `ansible-playbook deploy/openshift-clusters/kcli-install.yml -i deploy/openshift-clusters/inventory.ini`

---

### Dev-scripts Installation Configuration

**Purpose**: Deploy OpenShift using traditional dev-scripts method (arbiter or fencing)

**Prerequisites to check:**
- Ansible collections installed
- SSH key exists

**Files to configure:**

1. **Inventory file**: [deploy/openshift-clusters/inventory.ini](deploy/openshift-clusters/inventory.ini)
   - Same as previous sections (skip if already configured)

2. **Topology config files** in [deploy/openshift-clusters/roles/dev-scripts/install-dev/files/](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/):

   a. **Arbiter config**: [config_arbiter.sh](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_arbiter.sh)
      - Template: [config_arbiter_example.sh](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_arbiter_example.sh)
      - Check if exists
      - User must set:
        - `OPENSHIFT_RELEASE_IMAGE` (e.g., `quay.io/openshift-release-dev/ocp-release:4.19.0-rc.5-multi-x86_64`)
        - `CI_TOKEN` (unless using `OPENSHIFT_CI="True"`)
      - Suggest copying: `cp deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_arbiter_example.sh deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_arbiter.sh`

   b. **Fencing config**: [config_fencing.sh](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_fencing.sh)
      - Template: [config_fencing_example.sh](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_fencing_example.sh)
      - Check if exists
      - Same requirements as arbiter config
      - Suggest copying: `cp deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_fencing_example.sh deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_fencing.sh`

   - **CI Token guide**:
     - Visit: https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com
     - Click name (top right) → "Copy login command" → "Display Token"
     - Copy the API token

   - **Config reference**: https://github.com/openshift-metal3/dev-scripts/blob/master/config_example.sh

3. **Pull secret**: [deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json)
   - **NOTE**: This is the same pull secret used by kcli
   - Check if file exists here OR at [deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json](deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json)
   - If it exists in either location, offer to copy it to the other location
   - If it doesn't exist anywhere:
     - User gets pull secret from: https://cloud.redhat.com/openshift/install/pull-secret
     - Suggest creating file and pasting content

4. **SSH key configuration**:
   - Default location: `~/.ssh/id_ed25519.pub`
   - If user's key is elsewhere, they need to update: [deploy/openshift-clusters/roles/config/tasks/main.yaml](deploy/openshift-clusters/roles/config/tasks/main.yaml)

5. **Ansible collections**:
   - Check if [collections/requirements.yml](collections/requirements.yml) exists
   - Suggest: `ansible-galaxy collection install -r collections/requirements.yml`

**Validation:**
- Verify [inventory.ini](deploy/openshift-clusters/inventory.ini) exists
- For arbiter: Check [config_arbiter.sh](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_arbiter.sh) exists
- For fencing: Check [config_fencing.sh](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_fencing.sh) exists
- Verify [pull-secret.json](deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json) exists
- Validate pull secret is valid JSON: `jq . < deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json`
- Verify SSH key exists

**Next steps:**
- Interactive: `ansible-playbook deploy/openshift-clusters/setup.yml -i deploy/openshift-clusters/inventory.ini`
- Non-interactive arbiter: `ansible-playbook deploy/openshift-clusters/setup.yml -e "topology=arbiter" -e "interactive_mode=false" -i deploy/openshift-clusters/inventory.ini`
- Non-interactive fencing: `ansible-playbook deploy/openshift-clusters/setup.yml -e "topology=fencing" -e "interactive_mode=false" -i deploy/openshift-clusters/inventory.ini`

---

## General Workflow

1. **Parse the command argument** to determine what to configure
2. **If no argument or unclear**, ask the user interactively what they want to set up
   - Present options: external, aws, kcli, dev-scripts, all
   - Default suggestion: aws + dev-scripts
3. **For each selected configuration method**:
   - Announce what you're configuring
   - Check prerequisites and current state
   - **Process ONE step at a time** following this pattern:
     a. Identify the next action needed (copy file, edit file, install package, etc.)
     b. Provide clear instructions for that ONE action
     c. **STOP and wait for user confirmation that the step is complete**
     d. When user resumes, **verify the step was completed** before proceeding
     e. Only after verification, move to the next step
4. **After all steps for a method are complete**:
   - Perform final validation
   - Suggest next steps
   - If configuring multiple methods, move to the next method

## Interactive Step-by-Step Pattern

**CRITICAL**: You must follow this pattern for EVERY action:

### For Actions Claude Can Execute (file operations, checks, etc.):

1. **Announce and execute**: "Let me [action]..." then use the appropriate tool
   - File copying: Use Bash tool to copy files
   - File reading: Use Read tool to check files
   - Validation: Use Bash/Read tools to verify
2. **If user rejects the tool**: Fall back to manual instructions
   - Provide the command for the user to run
   - Ask them to let you know when done
3. **After execution (or user completion)**:
   - Verify the result
   - Move to next step or stop if user input is needed

### For Actions Requiring User Input (editing files, obtaining credentials, etc.):

1. **Present the action**: "Next, you need to [action]. Here's how..."
2. **Give specific instructions**: What to edit, where to get credentials, etc.
3. **STOP**: End your response and wait for the user
4. **On resume**:
   - First, check if the step was completed (read files, run validation commands)
   - If complete: Acknowledge and move to next step
   - If incomplete: Ask what went wrong and help troubleshoot
   - Never assume a step is complete without verification

**Example flow (Claude executes):**

```
Assistant: "Let me copy the inventory template for you."
[Uses Bash tool: cp deploy/openshift-clusters/inventory.ini.sample deploy/openshift-clusters/inventory.ini]

"Great! I've created the inventory file. Now you need to edit it with your host information. Please update:
- The host IP address
- The SSH user
- (Optional) sudo password

Let me know when you've edited the file."

[STOP - Wait for user]

User: "Done"

Assistant: [Checks if file exists]

"Great\! I can see the inventory file has been created. Now let's edit it with your host information..."

[Proceed to next step]
```

## What Claude Should Execute vs. What Requires User Action

### Claude Should Execute (Proactively):
- Copying template files (cp commands)
- Reading files to check if they exist
- Validating file contents (jq, grep, etc.)
- Checking prerequisites (which, ls, etc.)
- Any read-only or safe file operations

### User Must Do (Claude provides instructions):
- Editing files with user-specific values (IP addresses, credentials, etc.)
- Obtaining external resources (pull secrets, CI tokens, activation keys)
- Installing packages (ansible-galaxy, dnf, etc.) - unless user explicitly asks
- Setting environment variables in their shell
- Running deployment playbooks (final steps)

### Fallback Pattern:
If user rejects a tool use that Claude tried to execute:
1. Apologize briefly
2. Provide the manual command
3. Ask user to run it and confirm when done
4. Continue with verification step when they resume

## Important Notes

- Always check if files already exist before suggesting to create them
- Use file path links in markdown format: `[filename](path/to/file)` for VSCode clickability
- Distinguish between files that can be copied as-is vs. files that need editing
- Be clear about which values are required vs. optional
- After each user action, VERIFY it was completed before proceeding
- If prerequisites are missing, clearly state what needs to be installed
- Remember that some files are shared between methods:
  - `inventory.ini` is shared between external, kcli, and dev-scripts
  - `pull-secret.json` is shared between kcli and dev-scripts (same file, different locations)
  - When configuring multiple methods, check if shared files already exist and offer to copy them instead of recreating
- The main README states defaults: "By default, we'll configure the AWS hypervisor and the dev-scripts installation"
- **NEVER skip verification steps** - always confirm each action was completed successfully
- **STOP after giving each instruction** - wait for user to complete it and confirm
