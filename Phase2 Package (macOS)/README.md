# Phase2 Package (macOS)

Self-contained macOS deployment package for Phase2: everything Phase1 (macOS) does, plus Portal/Prelogon auto-connect configuration, a GlobalProtect connectivity check, and Netskope handling once connectivity is confirmed — mirroring the Windows Phase2 scope and structure. Uses `TEPL Phase2 macOS-v1.sh`, the first macOS version.

## Read this before using it — this is a first draft with real gaps, not a finished port

Three very different confidence levels are stacked in this one script. Please read this table before testing tomorrow, since it determines what a failure actually means:

| Part | Confidence | What could go wrong |
|---|---|---|
| Certificate install + GlobalProtect install | **High** — identical, tested logic to Phase1 macOS. | Needs the real `.pkg` filename in place of the `GlobalProtect.pkg` placeholder. |
| Portal/Prelogon plist configuration | **Low — unverified.** The plist domain (`/Library/Preferences/com.paloaltonetworks.GlobalProtect.settings`) and key structure are a best-effort guess based on the general pattern GlobalProtect macOS deployments are documented to use, not confirmed against a real installation or cross-checked against current official Palo Alto docs in this session. | If the domain/keys are wrong, this **silently writes to a plist GlobalProtect never reads** — it won't error, it just won't do anything. Watch for this specifically: certs + GP install succeeding is not evidence this part worked. |
| GlobalProtect background service restart | **Low — unverified.** `com.paloaltonetworks.gp.pangps` is a guessed LaunchDaemon label. | If wrong, the restart step logs a clear failure message (it doesn't fail silently), but the config change (even if written correctly) won't take effect until the service actually restarts. |
| GlobalProtect connectivity check | **Medium.** Scans all `utun*` interfaces for one with an IP inside `10.173.0.0/16`, rather than trying to match a specific interface name (since utun numbering isn't predictable and other VPN clients use utun too). Logic is sound and tested with a mocked `ifconfig`; not confirmed against a real connected session. | If GlobalProtect's real tunnel interface doesn't get an IP in this exact range, or another VPN's utun interface happens to match, this will misreport. |
| Netskope handling | **Not implemented at all.** Zero confirmed facts were available about the macOS Netskope client (install path, LaunchDaemon labels, uninstall mechanism, whether the same tamper-protection password applies) when this was written. | The script explicitly logs that Netskope handling is skipped and does **nothing** to Netskope — this was a deliberate choice: guessing at commands that stop/uninstall a security agent is worse than clearly doing nothing. **This is the main piece to fill in once you send over the Netskope Mac details.** |

## Deployment

1. Copy this entire `Phase2 Package (macOS)` folder anywhere on the target Mac.
2. Place the real GlobalProtect macOS installer package in `Installation File/`.
3. Run as root: `sudo "./Phase2 Script/TEPL Phase2 macOS-v1.sh"`
4. Watch progress / verify success in `Installation Logs/PANW-Phase2-Logs.txt`.

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
│   └── (place the GlobalProtect macOS .pkg/.mpkg here)
├── Installation Logs/
│   └── (created by the script on first run)
└── Phase2 Script/
    └── TEPL Phase2 macOS-v1.sh
```

## What the script does, in order

1. Everything Phase1 macOS does: certs into the System keychain, GlobalProtect installed via `installer`.
2. Writes Portal FQDN + Prelogon=1 to a preset plist (`configure_globalprotect_portal`) — **NEEDS CONFIRMATION**, see table above.
3. Restarts the GlobalProtect background service via `launchctl kickstart` — **NEEDS CONFIRMATION** on the exact daemon label.
4. Waits up to 5 minutes, polling every 10 seconds, for a `utun*` interface to show an IP inside `10.173.0.0/16` (the connectivity check).
5. **Only if connected**: calls the Netskope handling function — which currently just logs that it's not implemented and does nothing. **If not connected within 5 minutes**: skips straight to the final log message, same as Windows Phase2.

## What needs to happen before this is production-ready

In priority order:

1. **The real GlobalProtect macOS installer** (`.pkg`/`.mpkg` filename) — swap the placeholder in the script.
2. **Netskope macOS specifics** — install path, LaunchDaemon/process names, and whether the same tamper-protection password/uninstall mechanism from Windows applies. This is the biggest gap; `uninstall_netskope_agent` needs to be written from scratch once these are known (structurally, it should mirror the Windows `Uninstall-NetskopeAgent` — stop services, get uninstall info, attempt uninstall with the password, poll to confirm actual removal — but every command inside it needs macOS-specific facts this session didn't have).
3. **Confirm the Portal/Prelogon plist domain and key structure** against either a real installation (inspect what GlobalProtect itself writes/reads after a manual connect) or current official Palo Alto Networks macOS deployment documentation.
4. **Confirm the GlobalProtect LaunchDaemon label** (`launchctl list | grep -i paloalto` on a real installed machine will show the real label).
5. **Test on a real Mac** — nothing beyond mocked-command logic testing has been done, the same caveat that applied to every Windows script version before its first real-hardware test.

## Testing performed

Same approach as Phase1 macOS and every Windows script version: the real, unmodified script run against mocked `security`/`installer`/`launchctl`/`defaults`/`ifconfig`, plus real `openssl` for fingerprinting and real CIDR-range arithmetic (unit-tested in isolation with 6 boundary cases). Scenarios covered: full end-to-end run with GlobalProtect already connected (confirms the whole pipeline wires together correctly and reaches the Netskope stub), GlobalProtect not connected (confirms Netskope is correctly skipped), and the Portal/Prelogon configuration function running without crashing. All passed.

**Not tested:** whether the plist configuration or service restart actually affects a real GlobalProtect installation, whether the connectivity check correctly identifies a real GlobalProtect tunnel versus another VPN's utun interface, and (since it isn't implemented) anything Netskope-related at all.
