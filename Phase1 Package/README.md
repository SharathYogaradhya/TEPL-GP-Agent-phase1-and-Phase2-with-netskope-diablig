# Phase1 Package

Self-contained deployment package for Phase1 only (install certificates + GlobalProtect agent). No Netskope handling — that only exists in the Phase2 Package.

## Deployment

1. Copy this entire `Phase1 Package` folder onto the target machine as `C:\PaloAlto Package\` (i.e. the folder itself is renamed/placed at that path — the script's paths are hardcoded to `C:\PaloAlto Package\...`).
2. Download `GlobalProtect64.msi` from the [full package release](https://github.com/SharathYogaradhya/TEPL-GP-Agent-phase1-and-Phase2-with-netskope-diablig/releases/download/TEPLcompletepackage/PaloAlto.Package.zip) and place it in `Installation File\` (this binary is not stored in git; the `.gitkeep` file is a placeholder).
3. Run `Phase1 Script\TEPL Phase1 Windows-Final-v3.ps1` as Administrator.
4. Watch progress / verify success in `Installation Logs\PANW-Phase1-Logs.txt`.

## Contents

```
C:\PaloAlto Package\
├── Certificates\
│   ├── TEPL-Root-CA.pem
│   ├── Forward-Trust-CA.pem
│   └── Forward-Trust-CA-ECDSA.pem
├── Installation File\
│   └── GlobalProtect64.msi   (download separately, see step 2)
├── Installation Logs\
│   └── PANW-Phase1-Logs.txt  (created by the script on first run)
└── Phase1 Script\
    └── TEPL Phase1 Windows-Final-v3.ps1
```

This package carries `Phase1 Script/TEPL Phase1 Windows-Final-v3.ps1` at the repo root — a copy of the customer-validated original with these fixes, all local-machine-state checks (no GlobalProtect network/tunnel connectivity check — that stays in Phase2):
- The GlobalProtect MSI install checks its own exit code instead of unconditionally logging success right after `Start-Process` returns.
- The "already installed?" check uses the GlobalProtect registry uninstall entry instead of `Get-WmiObject Win32_Product`, which is slow, deprecated, and has the side effect of triggering a repair scan of every MSI-installed app on the machine.
- The fixed 45-second wait after install is replaced by polling for that same registry entry to actually appear.
- After restarting the GlobalProtect service, the script polls for it to actually reach `Running` instead of assuming success.

Certificate install, GlobalProtect agent install, and logging remain Phase1's whole scope — Portal/Prelogon configuration, confirming GlobalProtect actually connects, and any Netskope handling stay in Phase2. The original, unversioned `TEPL Phase1 Windows-Final.ps1` at the repo root is never modified.
