# Shared Netskope client functions (v2).
# Dot-source this file from a calling script (which must already define
# Write-Log) rather than importing it as a module, so these functions log
# to the calling script's own log file:
#   . "C:\PaloAlto Package\Netskope Script\Netskope-Functions-v2.ps1"
#
# Changes from v1 (Netskope-Functions.ps1):
# - Failures are inspected for signs of Netskope tamper protection /
#   enforcement (access denied, non-zero uninstaller exit codes) and
#   logged with actionable guidance instead of a bare exception message.

# Returns $true if the given error/exception text looks like it was
# blocked by tamper protection rather than a generic failure.
function Test-LooksLikeTamperProtection {
    param (
        [string]$errorText
    )
    return $errorText -match "Access is denied" -or $errorText -match "0x80070005"
}

function Write-TamperProtectionGuidance {
    Write-Log "This looks like Netskope Tamper Protection / enforcement blocking the action, not a generic script failure."
    Write-Log "Next steps: (1) obtain a disable password from the Netskope tenant admin console (Settings > Client Configuration > General) and re-run with `$netskopeDisablePassword set, or (2) ask the Netskope admin to temporarily exempt this device from tamper protection, or (3) have the admin push a remote uninstall/quarantine command from the Netskope console."
}

# Function to stop the Netskope client services
function Stop-NetskopeServices {
    $serviceNames = @("stAgentSvc", "nsdiag", "Netskope Client")
    $allStopped = $true

    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            try {
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
                Write-Log "Stopped service: $serviceName"
            } catch {
                $allStopped = $false
                Write-Log "Could not stop service $serviceName : $_"
                if (Test-LooksLikeTamperProtection -errorText "$_") {
                    Write-TamperProtectionGuidance
                }
            }
        }
    }

    return $allStopped
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
        $stopped = Stop-NetskopeServices

        $serviceNames = @("stAgentSvc", "nsdiag", "Netskope Client")
        foreach ($serviceName in $serviceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                try {
                    Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
                    Write-Log "Set service $serviceName startup type to Disabled."
                } catch {
                    Write-Log "Could not set startup type for $serviceName : $_"
                    if (Test-LooksLikeTamperProtection -errorText "$_") {
                        Write-TamperProtectionGuidance
                    }
                }
            }
        }

        if ($stopped) {
            Write-Log "Netskope client has been disabled."
        } else {
            Write-Log "Netskope client disable completed with warnings - one or more services could not be stopped. See guidance above."
        }
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

        Stop-NetskopeServices | Out-Null

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

        $exitCode = $null

        if ($uninstallString -match "msiexec") {
            # MSI-based uninstall
            $productCode = [regex]::Match($uninstallString, "\{[0-9A-Fa-f\-]+\}").Value
            $arguments = "/x `"$productCode`" /quiet /norestart"
            Write-Log "Running MSI uninstall: msiexec.exe $arguments"
            $proc = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
            $exitCode = $proc.ExitCode
        } else {
            # Inno Setup-based uninstaller (standard for Netskope client)
            $exePath = $uninstallString.Trim('"')
            $arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"

            if (-not [string]::IsNullOrWhiteSpace($NetskopeDisablePassword)) {
                $arguments += " /Password=$NetskopeDisablePassword"
            }

            Write-Log "Running uninstaller: `"$exePath`" $arguments"
            $proc = Start-Process -FilePath $exePath -ArgumentList $arguments -Wait -PassThru
            $exitCode = $proc.ExitCode
        }

        if ($exitCode -ne 0) {
            Write-Log "Uninstaller exited with non-zero code: $exitCode"
            if ([string]::IsNullOrWhiteSpace($NetskopeDisablePassword)) {
                Write-Log "No disable password was supplied. If tamper protection is enabled on this endpoint, this is almost certainly why the uninstall did not take effect."
            }
            Write-TamperProtectionGuidance
        }

        Start-Sleep -Seconds 15

        # Verify removal
        $stillPresent = Get-NetskopeUninstallInfo
        if ($stillPresent -or (Test-Path -Path $defaultUninstallerPath)) {
            Write-Log "Netskope client is still present after the uninstall attempt."
            if ($exitCode -eq 0) {
                Write-TamperProtectionGuidance
            }
        } else {
            Write-Log "Netskope client uninstalled successfully."
        }
    } catch {
        Write-Log "Error uninstalling Netskope client: $_"
        if (Test-LooksLikeTamperProtection -errorText "$_") {
            Write-TamperProtectionGuidance
        }
        exit 1
    }
}
