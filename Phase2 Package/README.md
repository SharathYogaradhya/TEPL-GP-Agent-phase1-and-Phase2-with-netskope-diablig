# Phase2 Package

Self-contained deployment package for Phase2 (certificates + GlobalProtect + Portal/Prelogon auto-connect config + Netskope uninstall once GlobalProtect is confirmed connected). Uses `TEPL Phase2 Windows-Final-v17.ps1`, the current latest version. Fully self-contained: the `GlobalProtect64.msi` installer is bundled in already, and the Netskope logic is inlined directly into the script — no separate `Netskope-Functions-*.ps1` file to place.

## Deployment

1. Copy this entire `Phase2 Package` folder anywhere on the target machine — **the folder can be named or placed anything**, it no longer has to be `C:\PaloAlto Package\`. As of v17, the script finds its own certs/MSI relative to its own location (`$PSScriptRoot`), not a hardcoded path.
2. Run `Phase2 Script\TEPL Phase2 Windows-Final-v17.ps1` as Administrator.
3. Watch progress / verify success in `Installation Logs\PANW-Phase2-Logs.txt` (created inside this same folder).

Netskope is only disabled/uninstalled once the script confirms GlobalProtect is actually connected (PanGPS running + tunnel adapter up + tunnel IP in `10.173.0.0/16`), waiting up to 5 minutes for that to happen (300 seconds, polling every 10s) to allow time for an interactive SSO/MFA login if the portal requires one. If that can't be confirmed within that window, Netskope is left untouched and the script says so in the log — re-run once GlobalProtect connects.

After each uninstall attempt, it also polls for up to 90 seconds to confirm Netskope is actually gone (folder + registry entry removed), instead of a single fixed 15-second wait — a real-machine test showed a genuinely successful uninstall could still take longer than 15 seconds to fully clean up, which an older fixed wait misreported as a failure.

## Contents

```
<this folder, wherever you place it>\
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
    └── TEPL Phase2 Windows-Final-v17.ps1
```

**New in v17:** the script computes its own package root from `$PSScriptRoot` (its own location) instead of hardcoding `C:\PaloAlto Package\...`. The folder can be named or placed anywhere — verified by actually running the same path-resolution logic from inside a folder named `Some Random Folder Name 123`, confirming all 6 files (certs + MSI) still resolve correctly with zero hardcoded path. This removes the entire class of "wrong path" failures from folder naming/placement mistakes, which matters especially when handing this off to a team (e.g. Intune) unfamiliar with the original hardcoded-path assumption.

Installs the GlobalProtect Prelogon Root CA certificate (`TEPL-PreLogon-CA.pem`, to the Trusted Root store) and the Prelogon Machine certificate (`TEPL-PreLogon-MachineCert.pfx`, to the Personal "My" store at both LocalMachine and CurrentUser) needed for Prelogon machine-certificate authentication. GlobalProtect fetches the cert from the machine (LocalMachine) store during the prelogon stage. The Machine cert must be a `.pfx` — a combined cert+encrypted-key `.pem` export was tested directly against this script's own certificate-loading code and loaded with `HasPrivateKey = False` (no error, but the private key silently dropped), so a plain `.pem`/`.der` export cannot be used for it.

This package carries a copy of `Phase2 Script/TEPL Phase2 Windows-Final-v17.ps1` at the repo root — that original file is never modified. If a future version becomes the recommended one, update the copy in this package rather than editing v17 in place.
