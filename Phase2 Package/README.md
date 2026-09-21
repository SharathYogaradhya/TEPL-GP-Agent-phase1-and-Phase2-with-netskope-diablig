# Phase2 Package

Self-contained deployment package for Phase2 (certificates + GlobalProtect + Portal/Prelogon auto-connect config + Netskope uninstall once GlobalProtect is confirmed connected). Uses `TEPL Phase2 Windows-Final-v12.ps1`, the current recommended version.

## Deployment

1. Copy this entire `Phase2 Package` folder onto the target machine as `C:\PaloAlto Package\` (i.e. the folder itself is renamed/placed at that path — the script's paths are hardcoded to `C:\PaloAlto Package\...`).
2. Download `GlobalProtect64.msi` from the [full package release](https://github.com/SharathYogaradhya/TEPL-GP-Agent-phase1-and-Phase2-with-netskope-diablig/releases/download/TEPLcompletepackage/PaloAlto.Package.zip) and place it in `Installation File\` (this binary is not stored in git; the `.gitkeep` file is a placeholder).
3. Run `Phase2 Script\TEPL Phase2 Windows-Final-v12.ps1` as Administrator.
4. Watch progress / verify success in `Installation Logs\PANW-Phase2-Logs.txt`.

Netskope is only disabled/uninstalled once the script confirms GlobalProtect is actually connected (PanGPS running + tunnel adapter up + tunnel IP in `10.173.0.0/16`), waiting up to 5 minutes for that to happen (raised from v10's 2 minutes to allow time for an interactive SSO/MFA login if the portal requires one). If that can't be confirmed within that window, Netskope is left untouched and the script says so in the log — re-run once GlobalProtect connects.

## Contents

```
C:\PaloAlto Package\
├── Certificates\
│   ├── TEPL-Root-CA.pem
│   ├── Forward-Trust-CA.pem
│   └── Forward-Trust-CA-ECDSA.pem
├── Installation File\
│   └── GlobalProtect64.msi        (download separately, see step 2)
├── Installation Logs\
│   └── PANW-Phase2-Logs.txt       (created by the script on first run)
├── Phase2 Script\
│   └── TEPL Phase2 Windows-Final-v12.ps1
└── Netskope Script\
    └── Netskope-Functions-v6.ps1  (dot-sourced by the Phase2 script)
```

This package is a copy of `Phase2 Script/TEPL Phase2 Windows-Final-v12.ps1` and `Netskope Script/Netskope-Functions-v6.ps1` at the repo root — those original files are never modified. If a future version (v13+) becomes the recommended one, update the copy in this package rather than editing v12 in place.
