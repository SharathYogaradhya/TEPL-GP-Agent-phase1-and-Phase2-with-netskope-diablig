#!/bin/bash
#
# TEPL Phase2 macOS v1
#
# Everything Phase1 macOS does (certs + GlobalProtect install), plus
# Portal/Prelogon auto-connect configuration, a GlobalProtect connectivity
# check, and Netskope handling once connectivity is confirmed - mirroring
# Windows Phase2's scope and structure.
#
# CONFIDENCE LEVELS (read this before using this script):
# - Certificates + GlobalProtect install: same mechanism as Phase1 macOS
#   v1, tested via a mocked harness (see Task tracking / commit history).
#   Confident this logic is correct; not yet run on a real Mac.
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
# - Netskope handling: NOT IMPLEMENTED. Zero confirmed facts were
#   available about the macOS Netskope client's install path, daemon
#   labels, or uninstall/tamper-protection mechanism at the time this was
#   written. Rather than guess at commands that stop/uninstall a security
#   agent, this logs clearly that it is skipped and does nothing further.
#   Fill in Uninstall-NetskopeAgent-equivalent logic once those facts are
#   confirmed - see the README.

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

# --- Certificate + GlobalProtect install (identical to Phase1 macOS v1;
# kept as a separate copy in this file rather than shared, matching the
# Windows Phase1/Phase2 convention of two independently maintained files) -

get_cert_fingerprint() {
    local cert_file="$1"
    local password="${2:-}"

    if [[ "$cert_file" == *.pfx || "$cert_file" == *.p12 ]]; then
        openssl pkcs12 -in "$cert_file" -passin "pass:${password}" -nokeys -clcerts -legacy 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
            | cut -d'=' -f2 | tr -d ':'
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

# --- Netskope handling: NOT IMPLEMENTED - see header notice ---------------
uninstall_netskope_agent() {
    write_log "Netskope macOS handling is not yet implemented - no confirmed install path, daemon labels, or uninstall/tamper-protection mechanism were available for the macOS Netskope client when this script was written. Skipping Netskope entirely on this run - it has not been touched. Provide those details to complete this function before relying on it."
}
# --- End Netskope handling placeholder -------------------------------------

# Main script execution
require_root

TRUSTED_ROOT_CERT_FILE="$PACKAGE_ROOT/Certificates/TEPL-Root-CA.pem"
DECRYPTION_CERT_FILE="$PACKAGE_ROOT/Certificates/Forward-Trust-CA.pem"
SECOND_DECRYPTION_CERT_FILE="$PACKAGE_ROOT/Certificates/Forward-Trust-CA-ECDSA.pem"
CERT_PASSWORD="123456789"
# NEEDS CONFIRMATION: filename of the actual GlobalProtect macOS installer
# package once provided - "GlobalProtect.pkg" is a placeholder name.
GLOBALPROTECT_INSTALLER_PATH="$PACKAGE_ROOT/Installation File/GlobalProtect.pkg"

PRELOGON_CA_ROOT_CERT_FILE="$PACKAGE_ROOT/Certificates/TEPL-PreLogon-CA.pem"
PRELOGON_MACHINE_CERT_FILE="$PACKAGE_ROOT/Certificates/TEPL-PreLogon-MachineCert.pfx"
PRELOGON_MACHINE_CERT_PASSWORD="123456789"

PORTAL_FQDN="tepl.gpcloudservice.com"

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
    uninstall_netskope_agent
else
    write_log "Skipping Netskope handling because GlobalProtect connectivity could not be verified. Re-run this script once GlobalProtect is confirmed connected."
fi

write_log "Installation of the Prisma Access Global Protect agent is now complete. Netskope handling ran only if GlobalProtect connectivity was verified - see log above for the outcome."
