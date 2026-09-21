# Phase1 Package

Self-contained deployment package for Phase1 only (install certificates + GlobalProtect agent). No Netskope handling — that only exists in the Phase2 Package. Fully self-contained: the `GlobalProtect64.msi` installer is bundled in here already, nothing to download separately.

## Deployment

1. Copy this entire `Phase1 Package` folder onto the target machine and place/rename it as `C:\PaloAlto Package\` (the script's paths are hardcoded to `C:\PaloAlto Package\...`).
2. Run `Phase1 Script\TEPL Phase1 Windows-Final-v4.ps1` as Administrator.
3. Watch progress / verify success in `Installation Logs\PANW-Phase1-Logs.txt`.

## Contents

```
C:\PaloAlto Package\
├── Certificates\
│   ├── TEPL-Root-CA.pem
│   ├── Forward-Trust-CA.pem
│   └── Forward-Trust-CA-ECDSA.pem
├── Installation File\
│   └── GlobalProtect64.msi   (bundled — no separate download needed)
├── Installation Logs\
│   └── PANW-Phase1-Logs.txt  (created by the script on first run)
└── Phase1 Script\
    └── TEPL Phase1 Windows-Final-v4.ps1
```

This package carries `Phase1 Script/TEPL Phase1 Windows-Final-v4.ps1` at the repo root — a copy of the customer-validated original with these fixes, all local-machine-state checks (no GlobalProtect network/tunnel connectivity check — that stays in Phase2):
- The GlobalProtect MSI install checks its own exit code instead of unconditionally logging success right after `Start-Process` returns.
- The "already installed?" check uses the GlobalProtect registry uninstall entry instead of `Get-WmiObject Win32_Product`, which is slow, deprecated, and has the side effect of triggering a repair scan of every MSI-installed app on the machine.
- The fixed 45-second wait after install is replaced by polling for that same registry entry to actually appear.
- After restarting the GlobalProtect service, the script polls for it to actually reach `Running` instead of assuming success.
- The service restart itself now treats a failure as a real, caught error (`-ErrorAction Stop`) instead of letting it print to the error stream and silently continue past it.

Certificate install, GlobalProtect agent install, and logging remain Phase1's whole scope — Portal/Prelogon configuration, confirming GlobalProtect actually connects, and any Netskope handling stay in Phase2. The original, unversioned `TEPL Phase1 Windows-Final.ps1` at the repo root is never modified.
