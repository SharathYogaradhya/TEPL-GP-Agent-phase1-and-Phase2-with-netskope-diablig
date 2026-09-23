#!/bin/bash
#
# TEPL Phase1 macOS v1
#
# Installs TEPL certs (Root CA + 2 decryption certs) + Prelogon certs (Root
# CA + Machine cert with private key) + the GlobalProtect agent. Mirrors
# Windows Phase1's scope exactly: no network connectivity checks, no
# Netskope handling - that is Phase2's job.
#
# Mechanisms used (macOS equivalents of the Windows Phase1 mechanisms):
# - Certificates: installed into the System keychain via `security`,
#   instead of the Windows Certificate Store API.
# - GlobalProtect: installed via `installer -pkg`, instead of msiexec.
# - "Already installed?" and "already present?" checks use `pkgutil`/app
#   bundle existence and certificate fingerprint comparison, instead of the
#   Windows registry.
#
# NEEDS CONFIRMATION before relying on this in production - see the
# "NEEDS CONFIRMATION" markers below and the README for the full list.

set -uo pipefail

# Resolve the package root from this script's own location, the same way
# the Windows scripts use $PSScriptRoot - this script always lives at
# <PackageRoot>/Phase1 Script/<this file>, so its parent's parent is the
# package root. Works no matter what the top-level folder is named or
# where it's placed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_DIR="$PACKAGE_ROOT/Installation Logs"
LOG_FILE="$LOG_DIR/PANW-Phase1-Logs.txt"
mkdir -p "$LOG_DIR"

# Function to log messages - mirrors Windows Write-Log (timestamped,
# printed to the console, and appended to the log file).
write_log() {
    local message="$1"
    local timestamp
    timestamp="$(date "+%Y-%m-%d %H:%M:%S")"
    echo "$timestamp - $message" | tee -a "$LOG_FILE"
}

# Function to check the script is running as root.
#
# There is no macOS equivalent of Windows UAC self-elevation (no silent
# re-launch with an elevation prompt from inside a script) - deployment
# tools (Jamf policies, Intune shell scripts run in the system context)
# already execute as root, so this checks and exits with a clear message
# rather than attempting a fake elevation trick.
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        write_log "This script must be run as root (e.g. 'sudo \"$0\"', or deployed via a tool that runs it as root)."
        exit 1
    fi
}

# Polls a condition (a bash command string, checked via eval) instead of a
# single fixed sleep - mirrors Windows Wait-ForCondition.
wait_for_condition() {
    local condition="$1"
    local max_wait_seconds="${2:-60}"
    local poll_interval_seconds="${3:-5}"
    local elapsed=0

    while [[ "$elapsed" -le "$max_wait_seconds" ]]; do
        if eval "$condition"; then
            return 0
        fi
        sleep "$poll_interval_seconds"
        elapsed=$((elapsed + poll_interval_seconds))
    done

    eval "$condition"
}

# Returns the SHA-1 fingerprint (no colons, uppercase) of a certificate
# file. Handles both a plain certificate (.pem/.der/.crt, no private key)
# and a PKCS#12 bundle (.pfx/.p12, cert + private key, needs a password to
# open) by extracting the leaf certificate from the PKCS#12 bundle first.
get_cert_fingerprint() {
    local cert_file="$1"
    local password="${2:-}"

    # Uses `cut -d'=' -f2` rather than matching the literal "SHA1
    # Fingerprint=" label text, since that label's casing/wording differs
    # between OpenSSL and LibreSSL builds (macOS's bundled openssl has
    # varied across versions) - splitting on '=' is robust to that.
    if [[ "$cert_file" == *.pfx || "$cert_file" == *.p12 ]]; then
        openssl pkcs12 -in "$cert_file" -passin "pass:${password}" -nokeys -clcerts -legacy 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
            | cut -d'=' -f2 | tr -d ':'
    else
        openssl x509 -in "$cert_file" -noout -fingerprint -sha1 2>/dev/null \
            | cut -d'=' -f2 | tr -d ':'
    fi
}

# Returns 0 (true) if a certificate with the given SHA-1 fingerprint is
# already present in the given keychain - the macOS equivalent of the
# Windows Is-CertInstalled thumbprint check.
is_cert_installed() {
    local fingerprint="$1"
    local keychain="$2"

    security find-certificate -Z -a "$keychain" 2>/dev/null \
        | grep -i "SHA-1 hash:" \
        | tr -d ' ' \
        | grep -qi "SHA-1hash:${fingerprint}"
}

# Installs a certificate into the given keychain, skipping it if a
# certificate with the same fingerprint is already present (idempotent,
# matching the Windows Install-Cert helper).
#
# - A plain certificate (no password, e.g. a Root/Intermediate CA with no
#   private key) is imported and trusted via `security add-trusted-cert`.
# - A PKCS#12 bundle (.pfx/.p12, has a private key, needs `password` to
#   open) is imported via `security import`, granting all applications
#   access to the private key (`-A`) so GlobalProtect can use it without
#   an interactive per-app permission prompt - the macOS equivalent of the
#   Windows Personal "My" store install.
install_cert() {
    local cert_file="$1"
    local keychain="$2"
    local password="${3:-}"

    local fingerprint
    fingerprint="$(get_cert_fingerprint "$cert_file" "$password")"

    if [[ -z "$fingerprint" ]]; then
        write_log "Could not read a certificate fingerprint from $cert_file - the file may be malformed or the password may be incorrect."
        return 1
    fi

    if is_cert_installed "$fingerprint" "$keychain"; then
        write_log "Certificate with fingerprint $fingerprint already exists in $keychain."
        return 0
    fi

    if [[ "$cert_file" == *.pfx || "$cert_file" == *.p12 ]]; then
        if security import "$cert_file" -k "$keychain" -P "$password" -A >/dev/null 2>&1; then
            write_log "Certificate (with private key) with fingerprint $fingerprint installed successfully in $keychain."
        else
            write_log "Failed to import certificate (with private key) from $cert_file into $keychain."
            return 1
        fi
    else
        if security add-trusted-cert -d -r trustRoot -k "$keychain" "$cert_file" >/dev/null 2>&1; then
            write_log "Certificate with fingerprint $fingerprint installed successfully in $keychain (trusted root)."
        else
            write_log "Failed to install certificate from $cert_file into $keychain."
            return 1
        fi
    fi
}

# Function to install certificates - mirrors Windows Install-Certificates:
# Root CA, 2 decryption certs, Prelogon Root CA (all trusted-root, no
# private key), and the Prelogon Machine cert (has a private key) into the
# System keychain (/Library/Keychains/System.keychain), which is what a
# machine-level daemon like GlobalProtect's PanGPS-equivalent reads from.
install_certificates() {
    local trusted_root_cert_file="$1"
    local decryption_cert_file="$2"
    local second_decryption_cert_file="$3"
    local cert_password="$4"
    local prelogon_ca_root_cert_file="$5"
    local prelogon_machine_cert_file="$6"
    local prelogon_machine_cert_password="$7"

    local system_keychain="/Library/Keychains/System.keychain"

    write_log "Installing certificates..."

    for f in "$trusted_root_cert_file" "$decryption_cert_file" "$second_decryption_cert_file" "$prelogon_ca_root_cert_file" "$prelogon_machine_cert_file"; do
        if [[ ! -f "$f" ]]; then
            write_log "Certificate file not found at path: $f"
            exit 1
        fi
    done

    install_cert "$trusted_root_cert_file" "$system_keychain" || exit 1
    install_cert "$decryption_cert_file" "$system_keychain" "$cert_password" || exit 1
    install_cert "$second_decryption_cert_file" "$system_keychain" "$cert_password" || exit 1
    install_cert "$prelogon_ca_root_cert_file" "$system_keychain" || exit 1
    install_cert "$prelogon_machine_cert_file" "$system_keychain" "$prelogon_machine_cert_password" || exit 1
}

# Returns 0 (true) if GlobalProtect is already installed - checked via the
# app bundle's existence, which does not depend on knowing the exact
# package receipt identifier used by the installer.
is_globalprotect_installed() {
    [[ -d "/Applications/GlobalProtect.app" ]]
}

# Function to install GlobalProtect - mirrors Windows Install-GlobalProtect:
# skip if already installed, otherwise install silently and confirm via
# polling instead of assuming success.
#
# NEEDS CONFIRMATION: the exact LaunchDaemon label for the GlobalProtect
# background service (used only for the informational check below, not to
# gate success) - GP_DAEMON_LABEL is a placeholder guess, not verified
# against a real Mac installation yet.
install_globalprotect() {
    local installer_pkg_path="$1"
    local gp_daemon_label="com.paloaltonetworks.gp.pangps" # NEEDS CONFIRMATION

    write_log "Installing GlobalProtect..."

    if is_globalprotect_installed; then
        write_log "GlobalProtect is already installed. Skipping installation."
        return 0
    fi

    if [[ ! -f "$installer_pkg_path" ]]; then
        write_log "GlobalProtect installer package not found at path: $installer_pkg_path"
        exit 1
    fi

    if installer -pkg "$installer_pkg_path" -target /; then
        write_log "GlobalProtect installer ran successfully (exit code 0)."
    else
        local exit_code=$?
        write_log "GlobalProtect installer failed (installer exit code: $exit_code). Installation did not complete successfully."
        exit 1
    fi

    if wait_for_condition "is_globalprotect_installed" 60 5; then
        write_log "GlobalProtect installed successfully (installer exit code: 0, /Applications/GlobalProtect.app confirmed present)."
    else
        write_log "installer reported success (exit code 0), but /Applications/GlobalProtect.app was not found within 60 seconds of waiting. Proceeding, but this is unexpected."
    fi

    if launchctl list 2>/dev/null | grep -qi "$gp_daemon_label"; then
        write_log "GlobalProtect background service ($gp_daemon_label) confirmed running."
    else
        write_log "Could not confirm the GlobalProtect background service ($gp_daemon_label) is running - this daemon label needs verification against a real installation; the app itself is installed regardless."
    fi
}

# Main script execution
require_root

# Define variables - all resolved relative to $PACKAGE_ROOT (computed at
# the top of this script from its own location), not a hardcoded fixed
# path - same convention as the Windows scripts.
TRUSTED_ROOT_CERT_FILE="$PACKAGE_ROOT/Certificates/TEPL-Root-CA.pem"
DECRYPTION_CERT_FILE="$PACKAGE_ROOT/Certificates/Forward-Trust-CA.pem"
SECOND_DECRYPTION_CERT_FILE="$PACKAGE_ROOT/Certificates/Forward-Trust-CA-ECDSA.pem"
CERT_PASSWORD="123456789"
# Confirmed 2026-09-23: the real GlobalProtect macOS installer filename.
GLOBALPROTECT_INSTALLER_PATH="$PACKAGE_ROOT/Installation File/GlobalProtect-6.2.8-c948.pkg"

# Prelogon Root CA + Machine certificate, needed for GlobalProtect Prelogon
# machine-certificate authentication - same certs as Windows Phase1, since
# these are cross-platform formats (.pem, .pfx/.p12 are the same PKCS#12
# format under different common extensions).
PRELOGON_CA_ROOT_CERT_FILE="$PACKAGE_ROOT/Certificates/TEPL-PreLogon-CA.pem"
PRELOGON_MACHINE_CERT_FILE="$PACKAGE_ROOT/Certificates/TEPL-PreLogon-MachineCert.pfx"
PRELOGON_MACHINE_CERT_PASSWORD="123456789"

install_certificates \
    "$TRUSTED_ROOT_CERT_FILE" \
    "$DECRYPTION_CERT_FILE" \
    "$SECOND_DECRYPTION_CERT_FILE" \
    "$CERT_PASSWORD" \
    "$PRELOGON_CA_ROOT_CERT_FILE" \
    "$PRELOGON_MACHINE_CERT_FILE" \
    "$PRELOGON_MACHINE_CERT_PASSWORD"

install_globalprotect "$GLOBALPROTECT_INSTALLER_PATH"

write_log "Installation of the Prisma Access Global Protect agent is now complete."
