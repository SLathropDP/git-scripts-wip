## Linux Onboarding (RHEL)

This repository includes a shell-based onboarding script that sets up the
minimum tooling required for the snippet mirroring system. The goal is to
ensure that the Node.js–based scripts and Git hooks can run successfully.

### What the onboarding script does

- Confirms that **Node.js** is already installed
  (Node.js is required, but the onboarding script does *not* install it)
- Installs **Pandoc** via the system package manager (`dnf` or `yum`)
- Enables the **EPEL repository** if needed (for RHEL-based systems)

This keeps onboarding quick and minimal, while ensuring all subsequent tools
(such as the Git pre-commit hook and the snippet mirror generation scripts)
are able to run.

### Running the Linux onboarding script

From the repository root:

```bash
chmod +x scripts/onboarding-linux.sh && ./scripts/onboarding-linux.sh
```
