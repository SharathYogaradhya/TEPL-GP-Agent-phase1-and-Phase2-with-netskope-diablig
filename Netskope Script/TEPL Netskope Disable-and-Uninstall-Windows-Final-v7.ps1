# Define the log file path
$logFilePath = "C:\PaloAlto Package\Installation Logs\Netskope-Disable-and-Uninstall-Logs.txt"

# Function to log messages
function Write-Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Write-Output $logMessage
    Add-Content -Path $logFilePath -Value $logMessage
}

# Function to check if the script is running as administrator
function Test-Administrator {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Shared Netskope functions (v7): polls for up to 90 seconds after each
# uninstall attempt to confirm removal, instead of a single fixed
# 15-second wait - a real-machine test run showed a genuinely successful
# uninstall (exit code 0) still misreported as "still present" because
# Netskope's own cleanup (folder/registry removal) hadn't finished within
# that fixed 15 seconds. Also carries v6's password fix and the v5 fixes:
# applies the disable password to MSI uninstalls via the PASSWORD public
# property, confirmed service name (stAgentSvc), confirmed MSI-based
# install and install folder, and no longer guesses an uninstall command
# if the registry entry can't be found.
$netskopeFunctionsPath = "C:\PaloAlto Package\Netskope Script\Netskope-Functions-v7.ps1"
if (-not (Test-Path -Path $netskopeFunctionsPath)) {
    Write-Log "Netskope-Functions-v7.ps1 not found at path: $netskopeFunctionsPath"
    exit 1
}
. $netskopeFunctionsPath

# Main script execution
if (-not (Test-Administrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $arguments = $args -join ' '
    Write-Log "Script is not running as administrator. Restarting with elevated privileges."
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $arguments" -Verb RunAs
    exit
}

Write-Log "Script is running with administrative privileges."
Write-Log "This script disables the Netskope client, attempts a plain uninstall, and only retries with a password if that first attempt does not actually remove the client."

# Real Netskope tenant disable/uninstall password, provided by the
# customer. Applied to MSI uninstalls via the confirmed PASSWORD property
# only if the initial password-free attempt does not remove the client.
#
# Corrected in v6: the password is case-sensitive and was previously
# stored as "june@2026!@" (lowercase j). A real-machine test run showed
# the password retry step failing with the same MSI exit code as the
# plain attempt, which pointed at the password itself - the customer
# then confirmed the correct casing is "June@2026!@" (capital J).
$netskopeDisablePassword = "June@2026!@"

# Disable first - stopping/disabling the services before uninstalling avoids the
# agent's watchdog restarting the process mid-uninstall.
Disable-NetskopeAgent

# Then attempt removal: plain uninstall first, password retry only if needed.
Uninstall-NetskopeAgent -NetskopeDisablePassword $netskopeDisablePassword

if (Test-NetskopeInstalled) {
    Write-Log "FINAL CHECK: Netskope client is still present on this machine."
} else {
    Write-Log "FINAL CHECK: Netskope client is confirmed removed from this machine."
}

# Final notification to the user
Write-Log "Netskope disable-and-uninstall script execution is now complete."
Write-Output "Netskope disable-and-uninstall script execution is now complete."
