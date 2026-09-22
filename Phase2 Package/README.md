# Phase2 Package

Self-contained deployment package for Phase2 (certificates + GlobalProtect + Portal/Prelogon auto-connect config + Netskope uninstall once GlobalProtect is confirmed connected). Uses `TEPL Phase2 Windows-Final-v18.ps1`, the current latest version. Fully self-contained: the `GlobalProtect64.msi` installer is bundled in already, and the Netskope logic is inlined directly into the script — no separate `Netskope-Functions-*.ps1` file to place.

## Deployment

1. Copy this entire `Phase2 Package` folder anywhere on the target machine — **the folder can be named or placed anything**, it no longer has to be `C:\PaloAlto Package\`. The script finds its own certs/MSI relative to its own location (`$PSScriptRoot`), not a hardcoded path.
2. Run `Phase2 Script\TEPL Phase2 Windows-Final-v18.ps1` as Administrator.
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
    └── TEPL Phase2 Windows-Final-v18.ps1
```

**New in v18 — fixes a real bug found on real hardware:** the Portal/Prelogon registry writes (`Set-ItemProperty`) would throw "Cannot find path... because it does not exist" if the target key wasn't already there — on a real test machine, this happened for the per-user `HKCU:\SOFTWARE\Palo Alto Networks\GlobalProtect` key, because GlobalProtect was already installed but that user account had never actually launched it (the per-user key gets created by the running client, not the MSI installer). Since this was a non-terminating PowerShell error, the script didn't stop — it printed the error and then logged "User level portal FQDN configured" right after anyway, which was **false**: the value was never actually set. v18 ensures the key exists (creating it with `New-Item -Force` if missing) before writing to it, for all 4 registry writes (HKCU and HKLM, Portal and Prelogon). Verified by reproducing the exact real-machine condition (HKCU key missing, HKLM key present) against the real, unmodified function — confirmed both HKCU values are now actually set, with zero errors.

While fixing this, `Install-GlobalProtect` was also brought up to the same standard as Phase1's version (which had already been through this hardening and never got ported back to Phase2's separate copy of this function):
- Replaced `Get-WmiObject Win32_Product` (slow, deprecated, triggers a repair-scan side effect) with a registry-based "already installed" check.
- The MSI install now checks its own exit code and polls for the registry entry to appear, instead of a blind 45-second sleep.
- `Restart-Service` now uses `-ErrorAction Stop` and polls for the service to actually reach `Running`, instead of assuming success.

Installs the GlobalProtect Prelogon Root CA certificate (`TEPL-PreLogon-CA.pem`, to the Trusted Root store) and the Prelogon Machine certificate (`TEPL-PreLogon-MachineCert.pfx`, to the Personal "My" store at both LocalMachine and CurrentUser) needed for Prelogon machine-certificate authentication. GlobalProtect fetches the cert from the machine (LocalMachine) store during the prelogon stage. The Machine cert must be a `.pfx` — a combined cert+encrypted-key `.pem` export was tested directly against this script's own certificate-loading code and loaded with `HasPrivateKey = False` (no error, but the private key silently dropped), so a plain `.pem`/`.der` export cannot be used for it.

This package carries a copy of `Phase2 Script/TEPL Phase2 Windows-Final-v18.ps1` at the repo root — that original file is never modified. If a future version becomes the recommended one, update the copy in this package rather than editing v18 in place.
