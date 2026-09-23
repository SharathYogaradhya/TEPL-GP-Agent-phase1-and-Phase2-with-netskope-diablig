# Phase2 Package (macOS)

Lives under `macOS/Phase2 Package` in the repo — same folder name and internal layout as the Windows `Phase2 Package`, just under a `macOS/` parent so the two platforms don't mix at the repo root.

Self-contained macOS deployment package for Phase2: everything Phase1 (macOS) does, plus Portal/Prelogon auto-connect configuration, a GlobalProtect connectivity check, and Netskope handling once connectivity is confirmed — mirroring the Windows Phase2 scope and structure. Uses `TEPL Phase2 macOS-v2.sh`.

## Read this before using it — real gaps remain, not a finished port

Different confidence levels are stacked in this one script. Please read this table before testing, since it determines what a failure actually means:

| Part | Confidence | What could go wrong |
|---|---|---|
| Certificate install + GlobalProtect install | **High** — identical, tested logic to Phase1 macOS. | Already using the real `.pkg` filename (`GlobalProtect-6.2.8-c948.pkg`). |
| Netskope handling | **Medium — implemented from Netskope's own official documentation** ("Uninstalling the Netskope Client", macOS section), not guessed. Install path and uninstaller invocation are directly sourced from that doc. | Two things from that same doc are still unconfirmed: (1) your Intune tenant needs a macOS Configuration Profile marking Netskope's System Extension "Removable" (Team ID `24W52P9M7W`) — without it, uninstall may hit an interactive credential prompt instead of running silently; (2) the doc itself gives two different spellings of the System Extension bundle ID in different sections — confirm the real one with `systemextensionsctl list` on an installed Mac. |
| Portal/Prelogon plist configuration | **Low — unverified.** The plist domain (`/Library/Preferences/com.paloaltonetworks.GlobalProtect.settings`) and key structure are a best-effort guess based on the general pattern GlobalProtect macOS deployments are documented to use, not confirmed against a real installation or cross-checked against current official Palo Alto docs in this session. | If the domain/keys are wrong, this **silently writes to a plist GlobalProtect never reads** — it won't error, it just won't do anything. Watch for this specifically: certs + GP install succeeding is not evidence this part worked. |
| GlobalProtect background service restart | **Low — unverified.** `com.paloaltonetworks.gp.pangps` is a guessed LaunchDaemon label. | If wrong, the restart step logs a clear failure message (it doesn't fail silently), but the config change (even if written correctly) won't take effect until the service actually restarts. |
| GlobalProtect connectivity check | **Medium.** Scans all `utun*` interfaces for one with an IP inside `10.173.0.0/16`, rather than trying to match a specific interface name (since utun numbering isn't predictable and other VPN clients use utun too). Logic is sound and tested with a mocked `ifconfig`; not confirmed against a real connected session. | If GlobalProtect's real tunnel interface doesn't get an IP in this exact range, or another VPN's utun interface happens to match, this will misreport. |

## New in v2 — real Netskope uninstall logic, sourced from Netskope's official documentation

Netskope's own "Uninstalling the Netskope Client" PDF (macOS section) confirmed:
- **Install path**: `/Library/Application Support/Netskope Client.app` (from Netskope's own Kandji detection script — this script uses a direct path check instead of `mdfind`, testing the same thing without depending on Spotlight indexing).
- **Uninstall command**: run the bundled uninstaller directly — `/Applications/Remove Netskope Client.app/Contents/MacOS/Remove Netskope Client uninstall_me <password>` — the macOS equivalent of Windows' `msiexec /x ... PASSWORD=...`.
- **System Extension identity** (needed for an Intune "Removable System Extension" Configuration Profile — the functional equivalent of Windows tamper-protection bypass): Team Identifier `24W52P9M7W`. The doc gives two spellings of the Bundle Identifier across different sections (`com.netskope.client.Netskope-Client.NetskopeClientMacAppProxy` with a hyphen vs. `com.netskope.client.NetskopeClient.NetskopeClientMacAppProxy` without) — the script uses the Intune section's spelling, flagged for confirmation against a real installed Mac.

The reused Windows disable password (`June@2026!@`) is plugged in as the default, since Netskope's disable password is a tenant-level setting rather than per-OS — but this hasn't been independently confirmed for macOS specifically.

Verified against the real, unmodified function with 5 mock scenarios (not installed, successful uninstall, stuck/uninstaller-does-nothing, missing uninstaller binary, no password configured) — all pass, and the invocation arguments exactly match the official documentation's examples in both the password and no-password cases.

## Deployment

1. Copy this entire `Phase2 Package` folder anywhere on the target Mac.
2. Run as root: `sudo "./Phase2 Script/TEPL Phase2 macOS-v2.sh"`
3. Watch progress / verify success in `Installation Logs/PANW-Phase2-Logs.txt`.

## Contents

```
<this folder, wherever you place it>/
├── Certificates/
│   ├── TEPL-Root-CA.pem
│   ├── Forward-Trust-CA.pem
│   ├── Forward-Trust-CA-ECDSA.pem
│   ├── TEPL-PreLogon-CA.pem
│   └── TEPL-PreLogon-MachineCert.pfx
├── Installation File/
│   └── GlobalProtect-6.2.8-c948.pkg
├── Installation Logs/
│   └── (created by the script on first run)
└── Phase2 Script/
    └── TEPL Phase2 macOS-v2.sh
```

## What the script does, in order

1. Everything Phase1 macOS does: certs into the System keychain, GlobalProtect installed via `installer`.
2. Writes Portal FQDN + Prelogon=1 to a preset plist (`configure_globalprotect_portal`) — **NEEDS CONFIRMATION**, see table above.
3. Restarts the GlobalProtect background service via `launchctl kickstart` — **NEEDS CONFIRMATION** on the exact daemon label.
4. Waits up to 5 minutes, polling every 10 seconds, for a `utun*` interface to show an IP inside `10.173.0.0/16` (the connectivity check).
5. **Only if connected**: attempts the real Netskope uninstall (see "New in v2" above). **If not connected within 5 minutes**: skips straight to the final log message, same as Windows Phase2.

## What needs to happen before this is production-ready

In priority order:

1. **Set up the Intune "Removable System Extension" Configuration Profile for Netskope** (Team ID `24W52P9M7W`) — without it, the uninstall command may hang waiting on an interactive credential prompt that a non-interactive script run will never satisfy.
2. **Confirm the real System Extension Bundle Identifier** on an installed Mac via `systemextensionsctl list` — the official doc gives two different spellings.
3. **Confirm the Portal/Prelogon plist domain and key structure** against either a real installation (inspect what GlobalProtect itself writes/reads after a manual connect) or current official Palo Alto Networks macOS deployment documentation.
4. **Confirm the GlobalProtect LaunchDaemon label** (`launchctl list | grep -i paloalto` on a real installed machine will show the real label).
5. **Confirm the Netskope disable password applies the same way on macOS** as it does on Windows (tenant-level setting, so likely yes, but not independently verified).
6. **Test on a real Mac** — nothing beyond mocked-command logic testing has been done, the same caveat that applied to every Windows script version before its first real-hardware test.

## Testing performed

Same approach as Phase1 macOS and every Windows script version: the real, unmodified script run against mocked `security`/`installer`/`launchctl`/`defaults`/`ifconfig`, plus real `openssl` for fingerprinting and real CIDR-range arithmetic (unit-tested in isolation with 6 boundary cases). Scenarios covered: full end-to-end run with GlobalProtect already connected (confirms the whole pipeline wires together correctly), GlobalProtect not connected (confirms Netskope is correctly skipped), the Portal/Prelogon configuration function running without crashing, and 5 Netskope-specific scenarios (not installed, successful uninstall, stuck/uninstaller-does-nothing, missing uninstaller binary, no password configured). All passed.

**Not tested:** whether the plist configuration or service restart actually affects a real GlobalProtect installation, whether the connectivity check correctly identifies a real GlobalProtect tunnel versus another VPN's utun interface, and whether the documented Netskope uninstall command actually works against a real Netskope Mac client without the Intune Removable System Extension profile in place.
