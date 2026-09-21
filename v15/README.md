# v15

A fully self-contained deployment folder, one step further than `v14`: the Phase2 script and the standalone Netskope script no longer depend on a separate `Netskope-Functions-*.ps1` file at all. Each script now carries its own copy of the Netskope logic inline.

## Why this changed

Splitting the Netskope functions into their own dot-sourced file (`Netskope-Functions-v*.ps1`) was meant to avoid duplicating that logic between the Phase2 script and the standalone Netskope-only script. In practice, it caused most of the deployment friction seen so far that wasn't a real logic bug:

- The "Netskope-Functions-v6.ps1 not found at path" failure, when the functions file wasn't copied to the exact expected folder.
- The confusing mismatch where the Phase2 script was on `v13` but the functions file it depended on was on `v7`.

v15 removes that whole failure class: **no second file to place correctly, and no version pairing to track.** The tradeoff is that the Netskope functions now exist in two places (a small amount of duplication) instead of one shared file — see the "one script total" alternative below if you'd rather avoid that tradeoff.

## What's inside

```
v15/
├── Certificates\
│   ├── TEPL-Root-CA.pem
│   ├── Forward-Trust-CA.pem
│   └── Forward-Trust-CA-ECDSA.pem
├── Installation File\
│   └── GlobalProtect64.msi
├── Installation Logs\
│   └── (created by the scripts on first run)
├── Phase1 Script\
│   └── TEPL Phase1 Windows-Final-v3.ps1          (adds an MSI exit-code check; certs+GP scope unchanged)
├── Phase2 Script\
│   └── TEPL Phase2 Windows-Final-v15.ps1      (fully self-contained — Netskope logic inlined)
└── Netskope Script\
    └── TEPL Netskope Disable-and-Uninstall-Windows-Final-v15.ps1   (fully self-contained, standalone)
```

Note there's no separate `Netskope-Functions-v15.ps1` — each script above is complete on its own.

## Deployment

1. Copy this entire `v15` folder onto the target machine and place/rename it as `C:\PaloAlto Package\` (the scripts' paths are hardcoded to `C:\PaloAlto Package\...`).
2. Run whichever script matches what you're testing, as Administrator:
   - `Phase1 Script\TEPL Phase1 Windows-Final-v3.ps1` — certs + GlobalProtect only.
   - `Phase2 Script\TEPL Phase2 Windows-Final-v15.ps1` — certs + GlobalProtect + Portal/Prelogon auto-connect + Netskope uninstall once GlobalProtect is confirmed connected.
   - `Netskope Script\TEPL Netskope Disable-and-Uninstall-Windows-Final-v15.ps1` — Netskope disable/uninstall on its own, independent of Phase1/Phase2.
3. Watch progress in `Installation Logs\` (`PANW-Phase1-Logs.txt`, `PANW-Phase2-Logs.txt`, or `Netskope-Disable-and-Uninstall-Logs.txt` depending on which script you ran).

## Functional behavior

Identical to `v14` (same Netskope password, same 90-second post-uninstall polling, same 5-minute GlobalProtect connectivity wait). Only the file structure changed — both scripts were parsed with PowerShell's own parser to confirm no syntax errors were introduced by inlining, and checked for duplicate function definitions (none found).

All prior versions, `v14/`, `Phase1 Package/`, and `Phase2 Package/` are left unmodified.
