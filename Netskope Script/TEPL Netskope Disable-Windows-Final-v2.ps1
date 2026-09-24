# Define the log file path
$logFilePath = "C:\PaloAlto Package\Installation Logs\Netskope-Disable-Logs.txt"

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

# Shared Netskope functions (v4): Disable-NetskopeAgent also disables any
# Netskope-related Scheduled Tasks and verifies the end state (service
# stopped + disabled) instead of assuming success, so the disable is
# intended to actually survive a restart.
$netskopeFunctionsPath = "C:\PaloAlto Package\Netskope Script\Netskope-Functions-v4.ps1"
if (-not (Test-Path -Path $netskopeFunctionsPath)) {
    Write-Log "Netskope-Functions-v4.ps1 not found at path: $netskopeFunctionsPath"
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
Write-Log "This script disables the Netskope client only. The software itself is not removed."

Disable-NetskopeAgent

# Final notification to the user
Write-Log "Netskope disable script execution is now complete."
Write-Output "Netskope disable script execution is now complete."
