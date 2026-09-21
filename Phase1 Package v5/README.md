# Phase1 Package v5

Self-contained deployment package for Phase1 only (install certificates + GlobalProtect agent, including the Prelogon Root CA and Machine certificate for GlobalProtect Prelogon machine-certificate authentication). No Netskope handling — that's Phase2's job. Fully self-contained: `GlobalProtect64.msi` is bundled in already, nothing to download separately.

## Deployment

1. Copy this entire `Phase1 Package v5` folder onto the target machine and place/rename it as `C:\PaloAlto Package\` (the script's paths are hardcoded to `C:\PaloAlto Package\...`).
2. Run `Phase1 Script\TEPL Phase1 Windows-Final-v5.ps1` as Administrator.
3. Watch progress / verify success in `Installation Logs\PANW-Phase1-Logs.txt`.

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
│   └── GlobalProtect64.msi   (bundled — no separate download needed)
├── Installation Logs\
│   └── PANW-Phase1-Logs.txt  (created by the script on first run)
└── Phase1 Script\
    └── TEPL Phase1 Windows-Final-v5.ps1
```

## What v5 does

All local-machine-state checks — no GlobalProtect network/tunnel connectivity check here, that stays in Phase2:
- Installs the 3 base certificates (Root CA + 2 decryption certs) to the Trusted Root store.
- Installs the Prelogon Root CA to the Trusted Root store, and the Prelogon Machine certificate (with its private key) to the Personal ("My") store at both LocalMachine and CurrentUser — GlobalProtect fetches it from the LocalMachine store during the prelogon stage. The Machine cert must be a `.pfx`: a combined cert+encrypted-key `.pem` export was tested directly against this script's own certificate-loading code and loaded with `HasPrivateKey = False` (silently dropping the key, no error), so a plain `.pem`/`.der` cannot be used for it.
- Installs GlobalProtect via MSI, checking the installer's own exit code rather than assuming success.
- Confirms the install actually landed (registry entry) and the service actually reaches `Running`, via polling rather than a fixed wait or a single check.

## Verification performed before this package was built

- Both `.ps1` files parsed cleanly with PowerShell's own AST parser (no syntax errors).
- The real, unmodified `Install-Certificates` function was run against all 5 real certificate files physically present in this exact folder (not copies elsewhere) with mocked certificate stores — 0 errors, all 6 expected store operations (4 root certs + the Machine cert into 2 separate Personal stores) completed.
- The Machine certificate's private key was independently confirmed (via `openssl`) to belong to the certificate, and the `.pfx` was confirmed to load with `HasPrivateKey: True` through the exact `X509Certificate2(path, password)` constructor this script uses.

This package carries a copy of `Phase1 Script/TEPL Phase1 Windows-Final-v5.ps1` at the repo root — that original file is never modified.
