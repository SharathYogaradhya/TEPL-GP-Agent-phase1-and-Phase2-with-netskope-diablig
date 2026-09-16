# Shared Netskope client functions.
# Dot-source this file from a calling script (which must already define
# Write-Log) rather than importing it as a module, so these functions log
# to the calling script's own log file:
#   . "C:\PaloAlto Package\Netskope Script\Netskope-Functions.ps1"

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
