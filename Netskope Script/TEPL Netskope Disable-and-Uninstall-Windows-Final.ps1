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

# Shared Netskope functions (Stop-NetskopeServices, Get-NetskopeUninstallInfo,
# Disable-NetskopeAgent, Uninstall-NetskopeAgent). Dot-sourced so they log
# through this script's own Write-Log function.
$netskopeFunctionsPath = "C:\PaloAlto Package\Netskope Script\Netskope-Functions-v2.ps1"
if (-not (Test-Path -Path $netskopeFunctionsPath)) {
    Write-Log "Netskope-Functions-v2.ps1 not found at path: $netskopeFunctionsPath"
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
Write-Log "This script disables the Netskope client first, then attempts to fully uninstall it."

# Only required if Netskope tamper protection / disable password is enabled on this endpoint. Leave blank otherwise.
$netskopeDisablePassword = ""

# Disable first - stopping/disabling the services before uninstalling avoids the
# agent's watchdog restarting the process mid-uninstall.
Disable-NetskopeAgent

# Then attempt full removal.
Uninstall-NetskopeAgent -NetskopeDisablePassword $netskopeDisablePassword

# Final notification to the user
Write-Log "Netskope disable-and-uninstall script execution is now complete."
Write-Output "Netskope disable-and-uninstall script execution is now complete."
