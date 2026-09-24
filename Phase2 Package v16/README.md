# Phase2 Package v16

Self-contained deployment package for Phase2 (certificates + Prelogon Root CA/Machine cert + GlobalProtect + Portal/Prelogon auto-connect config + Netskope uninstall once GlobalProtect is confirmed connected). Fully self-contained: `GlobalProtect64.msi` is bundled in already, and the Netskope logic is inlined directly into the script — no separate `Netskope-Functions-*.ps1` file to place.

## Deployment

1. Copy this entire `Phase2 Package v16` folder onto the target machine and place/rename it as `C:\PaloAlto Package\` (the script's paths are hardcoded to `C:\PaloAlto Package\...`).
2. Run `Phase2 Script\TEPL Phase2 Windows-Final-v16.ps1` as Administrator.
3. Watch progress / verify success in `Installation Logs\PANW-Phase2-Logs.txt`.

Netskope is only disabled/uninstalled once the script confirms GlobalProtect is actually connected (PanGPS running + tunnel adapter up + tunnel IP in `10.173.0.0/16`), waiting up to 5 minutes (300s, polling every 10s) to allow time for an interactive SSO/MFA login if the portal requires one. If that can't be confirmed within that window, Netskope is left untouched and the script logs why — re-run once GlobalProtect connects.

After each uninstall attempt, it polls for up to 90 seconds to confirm Netskope is actually gone (folder + registry entry removed), instead of a single fixed 15-second wait.

## Contents

```
C:\PaloAlto Package\
├── Certificates\
│   ├── TEPL-Root-CA.pem
│   ├── Forward-Trust-CA.pem
│   ├── Forward-Trust-CA-ECDSA.pem
│   ├── TEPL-PreLogon-CA.pem              (Prelogon Root CA, no private key)
│   └── TEPL-PreLogon-MachineCert.pfx     (Prelogon Machine cert + private key)
├── Installation File\
│   └── GlobalProtect64.msi        (bundled — no separate download needed)
├── Installation Logs\
│   └── PANW-Phase2-Logs.txt       (created by the script on first run)
└── Phase2 Script\
    └── TEPL Phase2 Windows-Final-v16.ps1
```

## What v16 does (Prelogon cert addition)

Installs the Prelogon Root CA to the Trusted Root store, and the Prelogon Machine certificate (with its private key) to the Personal ("My") store at both LocalMachine and CurrentUser — GlobalProtect fetches it from the LocalMachine store during the prelogon stage. The Machine cert must be a `.pfx`: a combined cert+encrypted-key `.pem` export was tested directly against this script's own certificate-loading code and loaded with `HasPrivateKey = False` (silently dropping the key, no error), so a plain `.pem`/`.der` cannot be used for it.

## Verification performed before this package was built

- The `.ps1` file parsed cleanly with PowerShell's own AST parser (no syntax errors).
- The real, unmodified `Install-Certificates` function was run against all 5 real certificate files physically present in this exact folder (not copies elsewhere) with mocked certificate stores — 0 errors, all 6 expected store operations (4 root certs + the Machine cert into 2 separate Personal stores) completed.
- The Machine certificate's private key was independently confirmed (via `openssl`) to belong to the certificate, and the `.pfx` was confirmed to load with `HasPrivateKey: True` through the exact `X509Certificate2(path, password)` constructor this script uses.

This package carries a copy of `Phase2 Script/TEPL Phase2 Windows-Final-v16.ps1` at the repo root — that original file is never modified.
