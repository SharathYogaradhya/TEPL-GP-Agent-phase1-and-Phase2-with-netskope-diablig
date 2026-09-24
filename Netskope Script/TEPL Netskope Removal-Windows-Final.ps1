# Define the log file path
$logFilePath = "C:\PaloAlto Package\Installation Logs\Netskope-Removal-Logs.txt"

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

# Function to stop the Netskope client services
function Stop-NetskopeServices {
    $serviceNames = @("stAgentSvc", "nsdiag", "Netskope Client")

    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            try {
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
                Write-Log "Stopped service: $serviceName"
            } catch {
                Write-Log "Could not stop service $serviceName : $_"
            }
        }
    }
}

# Function to find the Netskope uninstall string from the registry
function Get-NetskopeUninstallInfo {
    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($keyPath in $uninstallKeys) {
        $entries = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Netskope*" }

        if ($entries) {
            return $entries | Select-Object -First 1
        }
    }

    return $null
}

# Function to disable the Netskope client without uninstalling it
function Disable-NetskopeAgent {
    try {
        Write-Log "Disabling Netskope client (services will be stopped and set to disabled)."
        Stop-NetskopeServices

        $serviceNames = @("stAgentSvc", "nsdiag", "Netskope Client")
        foreach ($serviceName in $serviceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
                Write-Log "Set service $serviceName startup type to Disabled."
            }
        }

        Write-Log "Netskope client has been disabled."
    } catch {
        Write-Log "Error disabling Netskope client: $_"
        exit 1
    }
}

# Function to uninstall the Netskope client
function Uninstall-NetskopeAgent {
    param (
        [string]$NetskopeDisablePassword
    )

    try {
        Write-Log "Attempting to uninstall Netskope client..."

        Stop-NetskopeServices

        $uninstallInfo = Get-NetskopeUninstallInfo

        # Fall back to the default Inno Setup uninstaller path if the registry lookup fails
        $defaultUninstallerPath = "C:\Program Files (x86)\Netskope\STAgent\unins000.exe"

        if (-not $uninstallInfo -and -not (Test-Path -Path $defaultUninstallerPath)) {
            Write-Log "Netskope client was not found on this machine. Nothing to uninstall."
            return
        }

        if ($uninstallInfo) {
            Write-Log "Found Netskope entry: $($uninstallInfo.DisplayName)"
            $uninstallString = $uninstallInfo.UninstallString
        } else {
            Write-Log "Registry entry not found. Falling back to default uninstaller path."
            $uninstallString = $defaultUninstallerPath
        }

        if ($uninstallString -match "msiexec") {
            # MSI-based uninstall
            $productCode = [regex]::Match($uninstallString, "\{[0-9A-Fa-f\-]+\}").Value
            $arguments = "/x `"$productCode`" /quiet /norestart"
            Write-Log "Running MSI uninstall: msiexec.exe $arguments"
            Start-Process msiexec.exe -ArgumentList $arguments -Wait
        } else {
            # Inno Setup-based uninstaller (standard for Netskope client)
            $exePath = $uninstallString.Trim('"')
            $arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"

            if (-not [string]::IsNullOrWhiteSpace($NetskopeDisablePassword)) {
                $arguments += " /Password=$NetskopeDisablePassword"
            }

            Write-Log "Running uninstaller: `"$exePath`" $arguments"
            Start-Process -FilePath $exePath -ArgumentList $arguments -Wait
        }

        Start-Sleep -Seconds 15

        # Verify removal
        $stillPresent = Get-NetskopeUninstallInfo
        if ($stillPresent -or (Test-Path -Path $defaultUninstallerPath)) {
            Write-Log "Netskope client may still be present after uninstall attempt. If tamper protection is enabled, verify the disable password and re-run."
        } else {
            Write-Log "Netskope client uninstalled successfully."
        }
    } catch {
        Write-Log "Error uninstalling Netskope client: $_"
        exit 1
    }
}

# Main script execution
if (-not (Test-Administrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $arguments = $args -join ' '
    Write-Log "Script is not running as administrator. Restarting with elevated privileges."
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $arguments" -Verb RunAs
    exit
}

Write-Log "Script is running with administrative privileges."

# Define variables
# Set to "Uninstall" to fully remove the Netskope client, or "Disable" to stop and disable it without removing it.
$netskopeAction = "Uninstall"

# Only required if Netskope tamper protection / disable password is enabled on this endpoint. Leave blank otherwise.
$netskopeDisablePassword = ""

if ($netskopeAction -eq "Disable") {
    Disable-NetskopeAgent
} else {
    Uninstall-NetskopeAgent -NetskopeDisablePassword $netskopeDisablePassword
}

# Final notification to the user
Write-Log "Netskope removal/disable script execution is now complete."
Write-Output "Netskope removal/disable script execution is now complete."
