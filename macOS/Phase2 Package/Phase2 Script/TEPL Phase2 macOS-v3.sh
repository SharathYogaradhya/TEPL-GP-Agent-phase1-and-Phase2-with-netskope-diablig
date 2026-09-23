#!/bin/bash
#
# TEPL Phase2 macOS v3
#
# Everything Phase1 macOS does (certs + GlobalProtect install), plus
# Portal/Prelogon auto-connect configuration, a GlobalProtect connectivity
# check, and Netskope handling once connectivity is confirmed - mirroring
# Windows Phase2's scope and structure.
#
# CONFIDENCE LEVELS (read this before using this script):
# - Certificates + GlobalProtect install: same mechanism as Phase1 macOS
#   v2, tested via a mocked harness (see Task tracking / commit history).
#   Confident this logic is correct; not yet run on a real Mac. Changed in
#   v3: get_cert_fingerprint no longer hardcodes the OpenSSL "-legacy"
#   flag for the Prelogon Machine cert's PKCS#12 bundle - it tries without
#   it first (needed for LibreSSL, macOS's default system openssl, which
#   doesn't recognize that flag) and falls back to it only if needed.
#   Confirmed against the real TEPL-PreLogon-MachineCert.pfx that it
#   doesn't even need -legacy in the first place.
# - Portal/Prelogon plist configuration: best-effort, based on documented
#   GlobalProtect macOS deployment patterns, but the exact plist domain
#   and key names are NOT verified against a real installation or
#   official Palo Alto documentation in this session - see the
#   "NEEDS CONFIRMATION" markers below.
# - GlobalProtect connectivity check: best-effort utun-interface + CIDR
#   scan, conceptually mirroring the Windows adapter-description + IP
#   range check, but the exact interface identification needs real-
#   hardware confirmation (utun numbering is not predictable, and other
#   VPN clients also use utun interfaces).
# - Netskope handling: New in v2, implemented from Netskope's own official
#   "Uninstalling the Netskope Client" documentation (macOS section) - the
#   install path, uninstaller invocation, and System Extension identity
#   below are all sourced directly from that document, not guessed. Two
#   things from that same document still need real-hardware/customer-side
#   confirmation:
#   1. The customer's Intune tenant needs a macOS Configuration Profile
#      marking Netskope's System Extension as "Removable" (see
#      NETSKOPE_EXTENSION_TEAM_ID / NETSKOPE_EXTENSION_BUNDLE_ID below) -
#      without it, the documented uninstall command may still trigger an
#      interactive credential-approval prompt instead of running silently.
#      This is an Intune-side setup step this script cannot perform.
#   2. The document itself is inconsistent about the exact System
#      Extension bundle ID between its JAMF/Omnissa section
#      ("com.netskope.client.Netskope-Client.NetskopeClientMacAppProxy",
#      with a hyphen) and its Intune section
#      ("com.netskope.client.NetskopeClient.NetskopeClientMacAppProxy",
#      without one). NETSKOPE_EXTENSION_BUNDLE_ID below uses the Intune
#      section's spelling since that matches this deployment's tooling,
#      but this should be confirmed against a real installed Mac
#      (systemextensionsctl list) before relying on it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_DIR="$PACKAGE_ROOT/Installation Logs"
LOG_FILE="$LOG_DIR/PANW-Phase2-Logs.txt"
mkdir -p "$LOG_DIR"

write_log() {
    local message="$1"
    local timestamp
    timestamp="$(date "+%Y-%m-%d %H:%M:%S")"
    echo "$timestamp - $message" | tee -a "$LOG_FILE"
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        write_log "This script must be run as root (e.g. 'sudo \"$0\"', or deployed via a tool that runs it as root)."
        exit 1
    fi
}

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

# --- Certificate + GlobalProtect install (identical to Phase1 macOS v2;
# kept as a separate copy in this file rather than shared, matching the
# Windows Phase1/Phase2 convention of two independently maintained files) -

# Changed in v3: tries the PKCS#12 extraction WITHOUT the OpenSSL 3.x
# "-legacy" provider flag first, falling back to it only if that produced
# nothing. Earlier versions always passed -legacy - but macOS ships
# LibreSSL as its system `openssl` by default, which does not recognize
# that flag at all. Testing directly against the real
# TEPL-PreLogon-MachineCert.pfx confirmed it doesn't even need -legacy in
# the first place, so the old hardcoded -legacy was both unnecessary and a
# real risk of erroring out entirely on LibreSSL.
get_cert_fingerprint() {
    local cert_file="$1"
    local password="${2:-}"

    if [[ "$cert_file" == *.pfx || "$cert_file" == *.p12 ]]; then
        local fp
        fp=$(openssl pkcs12 -in "$cert_file" -passin "pass:${password}" -nokeys -clcerts 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
            | cut -d'=' -f2 | tr -d ':')

        if [[ -z "$fp" ]]; then
            fp=$(openssl pkcs12 -in "$cert_file" -passin "pass:${password}" -nokeys -clcerts -legacy 2>/dev/null \
                | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
                | cut -d'=' -f2 | tr -d ':')
        fi

        echo "$fp"
    else
        openssl x509 -in "$cert_file" -noout -fingerprint -sha1 2>/dev/null \
            | cut -d'=' -f2 | tr -d ':'
    fi
}

is_cert_installed() {
    local fingerprint="$1"
    local keychain="$2"

    security find-certificate -Z -a "$keychain" 2>/dev/null \
        | grep -i "SHA-1 hash:" \
        | tr -d ' ' \
        | grep -qi "SHA-1hash:${fingerprint}"
}

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

is_globalprotect_installed() {
    [[ -d "/Applications/GlobalProtect.app" ]]
}

# NEEDS CONFIRMATION: the exact LaunchDaemon label for the GlobalProtect
# background service - used for the restart/confirmation steps below.
GP_DAEMON_LABEL="com.paloaltonetworks.gp.pangps"

install_globalprotect() {
    local installer_pkg_path="$1"

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
}

# --- Portal/Prelogon configuration (macOS-specific, NEEDS CONFIRMATION) ---
#
# Windows Phase2 writes Portal/Prelogon values to the registry (HKCU and
# HKLM). The macOS equivalent GlobalProtect reads is documented (by Palo
# Alto Networks) as a preset plist under /Library/Preferences - this
# implementation targets that mechanism via `defaults write`, but the
# EXACT plist domain and key path below have not been verified against a
# real GlobalProtect macOS installation or cross-checked against current
# official Palo Alto documentation in this session. Confirm before relying
# on this - if the domain/keys are wrong, this will silently write to a
# plist GlobalProtect never reads, rather than fail loudly.
GP_SETTINGS_PLIST_DOMAIN="/Library/Preferences/com.paloaltonetworks.GlobalProtect.settings" # NEEDS CONFIRMATION

configure_globalprotect_portal() {
    local portal_fqdn="$1"

    write_log "Configuring GlobalProtect Portal/Prelogon settings (plist domain: $GP_SETTINGS_PLIST_DOMAIN - NEEDS CONFIRMATION)..."

    if defaults write "$GP_SETTINGS_PLIST_DOMAIN" "Palo Alto Networks" -dict-add "GlobalProtect" "$(cat <<PLIST
<dict>
    <key>PanSetup</key>
    <dict>
        <key>Portal</key>
        <string>${portal_fqdn}</string>
        <key>Prelogon</key>
        <integer>1</integer>
    </dict>
</dict>
PLIST
)" 2>/dev/null; then
        write_log "GlobalProtect Portal/Prelogon plist values written (pending confirmation this is the correct domain/key structure)."
    else
        write_log "Could not write GlobalProtect Portal/Prelogon plist values - this needs a confirmed domain/key structure before it will work. See the NEEDS CONFIRMATION note on GP_SETTINGS_PLIST_DOMAIN."
    fi

    # Restart the GlobalProtect background service so it picks up the
    # freshly-written settings - mirrors the Windows Restart-Service step,
    # and the Windows v21+ lesson that a client already running will not
    # pick up new config without being restarted.
    if launchctl kickstart -k "system/$GP_DAEMON_LABEL" >/dev/null 2>&1; then
        write_log "GlobalProtect background service ($GP_DAEMON_LABEL) restarted."
    else
        write_log "Could not restart the GlobalProtect background service ($GP_DAEMON_LABEL) - this daemon label needs confirmation against a real installation."
    fi
}

# --- GlobalProtect connectivity check (best-effort, NEEDS CONFIRMATION) ---
#
# Mirrors the Windows three-signal check (service running + adapter up +
# tunnel IP in range), adapted to macOS: GlobalProtect's tunnel typically
# appears as a utun* interface. Because utun numbering is not predictable
# and other VPN clients also use utun interfaces, this scans all utun
# interfaces for one with an IPv4 address in the confirmed range, rather
# than trying to match a specific interface name - but this has not been
# confirmed against a real connected session.
GP_TUNNEL_SUBNET_CIDR="10.173.0.0/16"

ip_in_cidr_range() {
    local ip="$1"
    local cidr="$2"
    local network="${cidr%/*}"
    local prefix="${cidr#*/}"

    local ip_int network_int mask
    ip_int=$(ip_to_int "$ip")
    network_int=$(ip_to_int "$network")
    mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))

    [[ $((ip_int & mask)) -eq $((network_int & mask)) ]]
}

ip_to_int() {
    local ip="$1"
    local a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

get_globalprotect_tunnel_ip() {
    local iface ip
    for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^utun'); do
        ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}')
        if [[ -n "$ip" ]] && ip_in_cidr_range "$ip" "$GP_TUNNEL_SUBNET_CIDR"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

is_globalprotect_connected() {
    get_globalprotect_tunnel_ip >/dev/null 2>&1
}

wait_for_globalprotect_connected() {
    local max_wait_seconds="${1:-300}"
    local poll_interval_seconds="${2:-10}"
    local elapsed=0
    local tunnel_ip

    write_log "Verifying GlobalProtect is connected before making any changes to Netskope (will wait up to ${max_wait_seconds} seconds)..."

    while [[ "$elapsed" -le "$max_wait_seconds" ]]; do
        if tunnel_ip="$(get_globalprotect_tunnel_ip)"; then
            write_log "GlobalProtect has a tunnel interface with IP address ($tunnel_ip) within the confirmed range ($GP_TUNNEL_SUBNET_CIDR). Treating GlobalProtect as connected."
            return 0
        fi
        sleep "$poll_interval_seconds"
        elapsed=$((elapsed + poll_interval_seconds))
    done

    write_log "Could not confirm GlobalProtect is connected (no utun interface found with a tunnel IP within $GP_TUNNEL_SUBNET_CIDR) within $max_wait_seconds seconds."
    return 1
}

# --- Netskope handling ------------------------------------------------------
#
# New in v2: implemented from Netskope's own official "Uninstalling the
# Netskope Client" documentation (macOS section), not guessed. See the
# header comment for the two things that document leaves genuinely
# unconfirmed (the Intune Removable-System-Extension setup, and a bundle-ID
# spelling inconsistency within the document itself).

# Confirmed from the official doc's own Kandji detection script: this is
# where the Netskope client installs. That script detects it via `mdfind`
# scoped to this folder; this uses a direct path check instead, which
# tests the same thing without depending on Spotlight indexing being current.
NETSKOPE_APP_PATH="/Library/Application Support/Netskope Client.app"

is_netskope_installed() {
    [[ -e "$NETSKOPE_APP_PATH" ]]
}

# Confirmed from the official doc: Netskope is removed by running its own
# bundled uninstaller app directly, passing "uninstall_me" and the
# tenant's uninstall password as arguments - this is the macOS equivalent
# of Windows' `msiexec /x ... PASSWORD=...`.
NETSKOPE_UNINSTALLER="/Applications/Remove Netskope Client.app/Contents/MacOS/Remove Netskope Client"

# NEEDS CONFIRMATION (Intune-side - not something this script can do):
# the official doc notes that removing Netskope's System Extension can
# prompt the user for credentials (twice, on macOS 11) unless an MDM
# Configuration Profile has already marked it "Removable". For Intune,
# that means a macOS Configuration Profile (Settings catalog > System
# Configuration > System Extensions > Removable System Extensions) needs
# to exist with this Team Identifier and Bundle Identifier, created by
# whoever administers your Intune tenant - this script only performs the
# uninstall itself, not that prerequisite MDM setup.
NETSKOPE_EXTENSION_TEAM_ID="24W52P9M7W"
# NEEDS CONFIRMATION: the source document gives two different spellings of
# this bundle ID in different sections (see header comment) - this is the
# Intune section's spelling. Confirm against a real installed Mac with
# `systemextensionsctl list` before relying on it for the Configuration
# Profile.
NETSKOPE_EXTENSION_BUNDLE_ID="com.netskope.client.NetskopeClient.NetskopeClientMacAppProxy"

# Polls until Netskope is confirmed removed or the wait window expires,
# rather than trusting the uninstaller's exit code alone - mirrors
# Wait-ForNetskopeRemoved on Windows.
wait_for_netskope_removed() {
    local max_wait_seconds="${1:-90}"
    local poll_interval_seconds="${2:-15}"
    local elapsed=0

    while [[ "$elapsed" -le "$max_wait_seconds" ]]; do
        if ! is_netskope_installed; then
            return 0
        fi
        sleep "$poll_interval_seconds"
        elapsed=$((elapsed + poll_interval_seconds))
    done

    ! is_netskope_installed
}

uninstall_netskope_agent() {
    local netskope_disable_password="${1:-}"

    write_log "Attempting to uninstall Netskope client..."

    if ! is_netskope_installed; then
        write_log "Netskope client was not found on this machine (checked $NETSKOPE_APP_PATH). Nothing to uninstall."
        return 0
    fi

    if [[ ! -x "$NETSKOPE_UNINSTALLER" ]]; then
        write_log "Netskope appears to be installed (found $NETSKOPE_APP_PATH) but its uninstaller was not found at the expected path: $NETSKOPE_UNINSTALLER. Manual removal or an action from the Netskope admin console is required."
        return 1
    fi

    if [[ -z "$netskope_disable_password" ]]; then
        write_log "No disable password is configured. Attempting uninstall without one (per the official doc's basic example) - this will fail if tamper protection / a required password is enforced for this tenant, which is the confirmed case on Windows for this customer."
        "$NETSKOPE_UNINSTALLER" uninstall_me exit
    else
        write_log "Attempting uninstall with the configured disable password."
        "$NETSKOPE_UNINSTALLER" uninstall_me "$netskope_disable_password"
    fi

    if wait_for_netskope_removed 90 15; then
        write_log "Netskope client uninstalled successfully."
        return 0
    else
        write_log "Netskope client is still present after the uninstall attempt."
        write_log "This could mean: (1) the System Extension isn't marked Removable in Intune yet, so removal is waiting on an interactive credential-approval prompt that never happened in this non-interactive script run, (2) the configured password doesn't match this tenant's disable password, or (3) removal requires an action from the Netskope admin console."
        return 1
    fi
}
# --- End Netskope handling ---------------------------------------------

# Main script execution
require_root

TRUSTED_ROOT_CERT_FILE="$PACKAGE_ROOT/Certificates/TEPL-Root-CA.pem"
DECRYPTION_CERT_FILE="$PACKAGE_ROOT/Certificates/Forward-Trust-CA.pem"
SECOND_DECRYPTION_CERT_FILE="$PACKAGE_ROOT/Certificates/Forward-Trust-CA-ECDSA.pem"
CERT_PASSWORD="123456789"
# Confirmed 2026-09-23: the real GlobalProtect macOS installer filename.
GLOBALPROTECT_INSTALLER_PATH="$PACKAGE_ROOT/Installation File/GlobalProtect-6.2.8-c948.pkg"

PRELOGON_CA_ROOT_CERT_FILE="$PACKAGE_ROOT/Certificates/TEPL-PreLogon-CA.pem"
PRELOGON_MACHINE_CERT_FILE="$PACKAGE_ROOT/Certificates/TEPL-PreLogon-MachineCert.pfx"
PRELOGON_MACHINE_CERT_PASSWORD="123456789"

PORTAL_FQDN="tepl.gpcloudservice.com"

# NEEDS CONFIRMATION: this reuses the same Netskope tamper-protection
# disable password already confirmed for Windows (org-wide, per-tenant,
# not per-device or per-OS) - Netskope's disable password is a tenant-
# level setting, so it very likely applies here too, but that has not
# been independently confirmed for macOS specifically.
NETSKOPE_DISABLE_PASSWORD="June@2026!@"

install_certificates \
    "$TRUSTED_ROOT_CERT_FILE" \
    "$DECRYPTION_CERT_FILE" \
    "$SECOND_DECRYPTION_CERT_FILE" \
    "$CERT_PASSWORD" \
    "$PRELOGON_CA_ROOT_CERT_FILE" \
    "$PRELOGON_MACHINE_CERT_FILE" \
    "$PRELOGON_MACHINE_CERT_PASSWORD"

install_globalprotect "$GLOBALPROTECT_INSTALLER_PATH"

configure_globalprotect_portal "$PORTAL_FQDN"

if wait_for_globalprotect_connected 300 10; then
    uninstall_netskope_agent "$NETSKOPE_DISABLE_PASSWORD"
else
    write_log "Skipping Netskope handling because GlobalProtect connectivity could not be verified. Re-run this script once GlobalProtect is confirmed connected."
fi

write_log "Installation of the Prisma Access Global Protect agent is now complete. Netskope handling ran only if GlobalProtect connectivity was verified - see log above for the outcome."
