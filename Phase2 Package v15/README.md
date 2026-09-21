# Phase2 Package v15

Self-contained deployment package for Phase2 (certificates + GlobalProtect + Portal/Prelogon auto-connect config + Netskope uninstall once GlobalProtect is confirmed connected). Uses `TEPL Phase2 Windows-Final-v15.ps1`, the current latest version. Fully self-contained: the `GlobalProtect64.msi` installer is bundled in already, and the Netskope logic is inlined directly into the script — no separate `Netskope-Functions-*.ps1` file to place.

## Deployment

1. Copy this entire `Phase2 Package v15` folder onto the target machine and place/rename it as `C:\PaloAlto Package\` (the script's paths are hardcoded to `C:\PaloAlto Package\...`).
2. Run `Phase2 Script\TEPL Phase2 Windows-Final-v15.ps1` as Administrator.
3. Watch progress / verify success in `Installation Logs\PANW-Phase2-Logs.txt`.

## Contents

```
C:\PaloAlto Package\
├── Certificates\
│   ├── TEPL-Root-CA.pem
│   ├── Forward-Trust-CA.pem
│   └── Forward-Trust-CA-ECDSA.pem
├── Installation File\
│   └── GlobalProtect64.msi        (bundled — no separate download needed)
├── Installation Logs\
│   └── PANW-Phase2-Logs.txt       (created by the script on first run)
└── Phase2 Script\
    └── TEPL Phase2 Windows-Final-v15.ps1
```

## What's in v15

- GlobalProtect connectivity is confirmed (PanGPS running + tunnel adapter up + tunnel IP in `10.173.0.0/16`) before Netskope is touched at all, waiting up to **5 minutes** (300 seconds, polling every 10s) to allow time for an interactive SSO/MFA login if the portal requires one. If it can't be confirmed within that window, Netskope is left untouched and the script logs why — re-run once GlobalProtect connects.
- Netskope disable/uninstall password is the corrected `"June@2026!@"` (capital J).
- After each Netskope uninstall attempt, the script polls for up to 90 seconds to confirm it's actually gone (registry entry + install folder removed), instead of a single fixed 15-second wait that could misreport a genuinely successful uninstall as still present.
- The Netskope functions (stop services, disable scheduled tasks, MSI uninstall with the tamper-protection password, etc.) are inlined directly into this script — no dependency on a separate `Netskope-Functions-*.ps1` file, so there's nothing extra to misplace.

This package carries a copy of `Phase2 Script/TEPL Phase2 Windows-Final-v15.ps1` at the repo root — that original file is never modified. If a future version becomes the recommended one, a new package folder is created rather than editing this one in place.
