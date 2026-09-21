# v14

A fully self-contained deployment folder where every versioned script carries the same version number, `v14`, so there's no confusion about which files go together. Previously the current recommended scripts had mismatched numbers (`TEPL Phase2 Windows-Final-v13.ps1` depending on `Netskope-Functions-v7.ps1`, etc.) — this folder renumbers all three to `v14` with no functional change beyond that renumbering.

## What's inside

```
v14/
├── Certificates\
│   ├── TEPL-Root-CA.pem
│   ├── Forward-Trust-CA.pem
│   └── Forward-Trust-CA-ECDSA.pem
├── Installation File\
│   └── GlobalProtect64.msi
├── Installation Logs\
│   └── (created by the scripts on first run)
├── Phase1 Script\
│   └── TEPL Phase1 Windows-Final-v2.ps1   (adds an MSI exit-code check; certs+GP scope unchanged)
├── Phase2 Script\
│   └── TEPL Phase2 Windows-Final-v14.ps1
└── Netskope Script\
    ├── Netskope-Functions-v14.ps1                              (dot-sourced by the Phase2 script)
    └── TEPL Netskope Disable-and-Uninstall-Windows-Final-v14.ps1  (standalone equivalent, run on its own)
```

## Deployment

1. Copy this entire `v14` folder onto the target machine and place/rename it as `C:\PaloAlto Package\` (the scripts' paths are hardcoded to `C:\PaloAlto Package\...`).
2. Run whichever script matches what you're testing, as Administrator:
   - `Phase1 Script\TEPL Phase1 Windows-Final-v2.ps1` — certs + GlobalProtect only.
   - `Phase2 Script\TEPL Phase2 Windows-Final-v14.ps1` — certs + GlobalProtect + Portal/Prelogon auto-connect + Netskope uninstall once GlobalProtect is confirmed connected.
   - `Netskope Script\TEPL Netskope Disable-and-Uninstall-Windows-Final-v14.ps1` — Netskope disable/uninstall on its own, independent of Phase1/Phase2.
3. Watch progress in `Installation Logs\` (`PANW-Phase1-Logs.txt`, `PANW-Phase2-Logs.txt`, or `Netskope-Disable-and-Uninstall-Logs.txt` depending on which script you ran).

## What v14 actually changed vs. the previous versions

- **Netskope disable/uninstall password** corrected to `"June@2026!@"` (capital J) — a real-machine test showed the previous lowercase `"june@2026!@"` failing the password-protected uninstall retry.
- **Post-uninstall verification** now polls for up to 90 seconds instead of a single fixed 15-second wait — a real-machine test showed a genuinely successful uninstall (exit code 0) could still take longer than 15 seconds for Netskope's own cleanup (folder + registry removal) to finish, which the old fixed wait misreported as "still present."
- **GlobalProtect connectivity wait** is 5 minutes (raised from the original 2 minutes) to allow time for an interactive SSO/MFA login if the portal ever requires one.

These are the same fixes as `Phase2 Windows-Final-v13.ps1` + `Netskope-Functions-v7.ps1` + the standalone `v7` script — this folder just brings them together under one consistent version number.

The root-level `Phase2 Script/`, `Netskope Script/`, and `Phase2 Package/` folders still hold every prior iteration for history — nothing there was changed by creating this folder.
