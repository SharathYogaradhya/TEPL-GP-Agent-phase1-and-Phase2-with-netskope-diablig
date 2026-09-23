# Phase1 Package (macOS)

Lives under `macOS/Phase1 Package` in the repo — same folder name and internal layout as the Windows `Phase1 Package`, just under a `macOS/` parent so the two platforms don't mix at the repo root.

Self-contained macOS deployment package for Phase1: install certificates + the GlobalProtect agent. No Netskope handling, no Portal/Prelogon connect configuration — that is Phase2's job, mirroring the Windows package split exactly. Uses `TEPL Phase1 macOS-v2.sh`.

## Read this before using it: confidence levels

This has **not yet run on a real Mac**. It was built and tested the same way the Windows scripts were — by running the actual, unmodified script against a mocked environment (fake `security`/`installer`/`launchctl` commands standing in for macOS) and verifying every code path — but a mock can only prove the script's *logic* is correct, not that the real macOS commands behave exactly as assumed.

| Part | Confidence |
|---|---|
| Certificate install (Keychain via `security`) | High — standard, documented macOS commands; fingerprint-matching logic verified with real `openssl` **against the actual real `TEPL-PreLogon-MachineCert.pfx`** (not just a synthetic test cert), install/skip logic verified against the real script with mocked `security`. |
| GlobalProtect install (`installer -pkg`) | High — standard, documented mechanism; verified against the real script with a mocked `installer`. Already using the real `.pkg` filename (`GlobalProtect-6.2.8-c948.pkg`). |
| GlobalProtect background service check | Low — `com.paloaltonetworks.gp.pangps` is a guessed LaunchDaemon label, not confirmed against a real installation. Informational only; does not gate success. |

## New in v2 — fixed a real cross-platform openssl risk

v1's certificate fingerprint check hardcoded the OpenSSL 3.x `-legacy` flag when reading the Prelogon Machine cert's `.pfx`. macOS ships **LibreSSL** as its default system `openssl`, which doesn't recognize that flag at all — on a stock Mac this could have made the fingerprint check fail outright and abort the entire certificate installation step. Testing directly against the real `TEPL-PreLogon-MachineCert.pfx` also showed it doesn't even need `-legacy` in the first place. v2 tries the extraction without `-legacy` first, falling back to it only if that produces nothing — this works regardless of which `openssl` ends up in `PATH` on the target Mac (system LibreSSL or a Homebrew-installed OpenSSL 3.x).

## Deployment

1. Copy this entire `Phase1 Package` folder anywhere on the target Mac — the folder can be named or placed anywhere, since the script resolves its own certs/installer relative to its own location, not a hardcoded path.
2. Run as root: `sudo "./Phase1 Script/TEPL Phase1 macOS-v2.sh"`
3. Watch progress / verify success in `Installation Logs/PANW-Phase1-Logs.txt`.

## Contents

```
<this folder, wherever you place it>/
├── Certificates/
│   ├── TEPL-Root-CA.pem
│   ├── Forward-Trust-CA.pem
│   ├── Forward-Trust-CA-ECDSA.pem
│   ├── TEPL-PreLogon-CA.pem              (Prelogon Root CA, no private key)
│   └── TEPL-PreLogon-MachineCert.pfx     (Prelogon Machine cert + private key — same file as Windows; .pfx/.p12 are the same PKCS#12 format)
├── Installation File/
│   └── GlobalProtect-6.2.8-c948.pkg
├── Installation Logs/
│   └── (created by the script on first run)
└── Phase1 Script/
    └── TEPL Phase1 macOS-v2.sh
```

## What the script does, in order

1. Checks it's running as root (there's no macOS equivalent of Windows UAC self-elevation — deployment tools like Jamf/Intune already run scripts as root, so this just checks and exits with a clear message if not).
2. Installs certificates into the System keychain (`/Library/Keychains/System.keychain`), idempotently — each cert is skipped if a certificate with the same SHA-1 fingerprint is already present:
   - Trusted Root CA, decryption cert, second decryption cert, Prelogon Root CA — all installed via `security add-trusted-cert` (trusted root, no private key).
   - Prelogon Machine cert (`.pfx`, has a private key) — installed via `security import` with `-A` (grants all applications access to the private key without an interactive prompt, mirroring the Windows "no user interaction" requirement).
3. Installs GlobalProtect via `installer -pkg ... -target /` if not already installed (checked via `/Applications/GlobalProtect.app` existing), checks the installer's exit code, and polls up to 60 seconds to confirm the app bundle actually appears.

## What's different from Windows Phase1 (and why)

- **No self-elevation.** Windows UAC allows a script to silently relaunch itself elevated; macOS has no equivalent, so this checks for root and exits with instructions instead.
- **Certificate store is the macOS Keychain, not the Windows Certificate Store.** `security` replaces the `X509Store`/`X509Certificate2` APIs; the underlying cert files (`.pem`, `.pfx`) are unchanged and cross-platform.
- **"Already installed?" uses the app bundle's existence, not a package receipt ID** — this avoids needing to know GlobalProtect's exact macOS package identifier, which isn't confirmed yet.

## Testing performed

Built and verified using the same approach as the Windows scripts: running the real, unmodified script with `security`/`installer`/`launchctl` replaced by mock implementations, plus real `openssl` for certificate fingerprinting (this part needs no mocking — fingerprint computation is genuinely OS-independent, and was verified against the actual real `TEPL-PreLogon-MachineCert.pfx`, not just a synthetic test cert). Scenarios covered: fresh install, idempotent re-run (everything already present), missing certificate file, missing installer package, installer failure (non-zero exit code), and the not-running-as-root guard. All passed against the real script logic.

**Not yet tested:** actual behavior on a real Mac with the real GlobalProtect installer and real Keychain — this is the next required step before trusting this for production deployment.
