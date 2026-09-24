# Shared Netskope client functions (v6).
# Dot-source this file from a calling script (which must already define
# Write-Log) rather than importing it as a module, so these functions log
# to the calling script's own log file:
#   . "C:\PaloAlto Package\Netskope Script\Netskope-Functions-v6.ps1"
#
# Changes from v5 (Netskope-Functions-v5.ps1):
# - Confirmed via official Netskope documentation ("Uninstalling the
#   Netskope Client" - Windows section, both the Microsoft Endpoint
#   Configuration Manager script and the GPO batch script) that the MSI
#   public property for the tamper-protection uninstall password is
#   PASSWORD, e.g. `msiexec /x {GUID} PASSWORD=<password> /qn`. The MSI
#   branch of Invoke-NetskopeUninstaller now applies the configured
#   password using this confirmed property, instead of logging that it
#   couldn't be applied.
#
# Carried over from v5, based on real data collected from a machine with
# Netskope actually installed:
# - The confirmed real deployment uses an MSI installer (UninstallString of
#   the form "MsiExec.exe /I{GUID}"), not the Inno Setup unins000.exe an
#   earlier version assumed as a fallback. The install folder itself
#   (C:\Program Files (x86)\Netskope\STAgent) was confirmed correct via the
#   service's own binary path (Win32_Service PathName), so the fallback
#   presence check tests for that folder instead of a specific,
#   installer-type-specific file name.
# - If the registry uninstall entry can't be found AND we can't determine
#   the real uninstall command, Uninstall-NetskopeAgent does not guess at
#   a command to run - it logs that an automated uninstall command could
#   not be determined and stops, rather than attempting a command that
#   would just fail.

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

# Function to find and disable any Scheduled Tasks referencing Netskope,
# so a Disabled service can't be relaunched by a separate startup/logon
# task. Returns $true if no problems were hit disabling matching tasks
# (or none were found).
function Disable-NetskopeScheduledTasks {
    $allDisabled = $true

    try {
        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like "*Netskope*" -or $_.TaskPath -like "*Netskope*" }
    } catch {
        Write-Log "Could not query Scheduled Tasks: $_"
        return $false
    }

    if (-not $tasks) {
        Write-Log "No Netskope-related Scheduled Tasks found."
        return $true
    }

    foreach ($task in $tasks) {
        try {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
            Write-Log "Disabled Scheduled Task: $($task.TaskPath)$($task.TaskName)"
        } catch {
            $allDisabled = $false
            Write-Log "Could not disable Scheduled Task $($task.TaskPath)$($task.TaskName) : $_"
            if (Test-LooksLikeTamperProtection -errorText "$_") {
                Write-TamperProtectionGuidance
            }
        }
    }

    return $allDisabled
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

# Confirmed real install folder (from Win32_Service PathName on a live
# Netskope-installed machine), used as an installer-type-agnostic fallback
# presence check - not tied to a specific installer's uninstaller filename.
$script:NetskopeInstallFolder = "C:\Program Files (x86)\Netskope\STAgent"

# Returns $true if a Netskope client entry can still be found on the machine.
function Test-NetskopeInstalled {
    $info = Get-NetskopeUninstallInfo
    return ($null -ne $info) -or (Test-Path -Path $script:NetskopeInstallFolder)
}

# Function to disable the Netskope client without uninstalling it, in a
# way intended to survive a restart: stops the services, sets each to
# Disabled startup, disables any related Scheduled Tasks, then verifies
# the end state rather than assuming success.
function Disable-NetskopeAgent {
    try {
        Write-Log "Disabling Netskope client (services will be stopped and set to disabled)."
        $stopped = Stop-NetskopeServices

        $serviceNames = @("stAgentSvc", "nsdiag", "Netskope Client")
        $allDisabled = $true
        foreach ($serviceName in $serviceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                try {
                    Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
                    Write-Log "Set service $serviceName startup type to Disabled."
                } catch {
                    $allDisabled = $false
                    Write-Log "Could not set startup type for $serviceName : $_"
                    if (Test-LooksLikeTamperProtection -errorText "$_") {
                        Write-TamperProtectionGuidance
                    }
                }
            }
        }

        $tasksDisabled = Disable-NetskopeScheduledTasks

        # Verify the actual end state rather than assuming success
        $verificationPassed = $true
        foreach ($serviceName in $serviceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                $isStopped = $service.Status -eq "Stopped"
                $startType = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).StartType
                $isDisabled = $startType -eq "Disabled"

                if ($isStopped -and $isDisabled) {
                    Write-Log "Verified: $serviceName is stopped and set to Disabled - will not start automatically on next boot."
                } else {
                    $verificationPassed = $false
                    Write-Log "Verification FAILED for $serviceName (Status=$($service.Status), StartType=$startType). This service may restart on next boot or logon."
                }
            }
        }

        if ($stopped -and $allDisabled -and $tasksDisabled -and $verificationPassed) {
            Write-Log "Netskope client has been disabled and verified to not restart automatically."
        } else {
            Write-Log "Netskope client disable completed with warnings - see messages above. It may not survive a restart cleanly."
        }
    } catch {
        Write-Log "Error disabling Netskope client: $_"
        exit 1
    }
}

# Runs the Netskope uninstaller once, with an optional password, and
# returns its exit code.
#
# For an MSI-based install, the password is passed via the PASSWORD public
# property, confirmed from official Netskope documentation ("Uninstalling
# the Netskope Client" - Windows / Microsoft Endpoint Configuration Manager
# and GPO sections): msiexec /x {GUID} PASSWORD=<password> /qn
function Invoke-NetskopeUninstaller {
    param (
        [string]$UninstallString,
        [string]$NetskopeDisablePassword
    )

    if ($UninstallString -match "msiexec") {
        # MSI-based uninstall (confirmed the real install type for this deployment)
        $productCode = [regex]::Match($UninstallString, "\{[0-9A-Fa-f\-]+\}").Value
        $arguments = "/x `"$productCode`""

        if (-not [string]::IsNullOrWhiteSpace($NetskopeDisablePassword)) {
            $arguments += " PASSWORD=`"$NetskopeDisablePassword`""
        }

        $arguments += " /quiet /norestart"

        Write-Log "Running MSI uninstall: msiexec.exe $arguments"
        $proc = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
    } else {
        # Inno Setup-based uninstaller (some Netskope deployments use this instead of MSI)
        $exePath = $UninstallString.Trim('"')
        $arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"

        if (-not [string]::IsNullOrWhiteSpace($NetskopeDisablePassword)) {
            $arguments += " /Password=$NetskopeDisablePassword"
        }

        Write-Log "Running uninstaller: `"$exePath`" $arguments"
        $proc = Start-Process -FilePath $exePath -ArgumentList $arguments -Wait -PassThru
    }

    return $proc.ExitCode
}

# Function to uninstall the Netskope client.
# Step 1: try a plain uninstall with no password.
# Step 2: only if step 1 did not actually remove the client, retry once
#         with the supplied disable password via the confirmed PASSWORD
#         MSI property (treating the failure as a likely tamper-protection
#         block).
# Each step is verified by re-checking whether Netskope is still present,
# not just by trusting the uninstaller's exit code.
function Uninstall-NetskopeAgent {
    param (
        [string]$NetskopeDisablePassword
    )

    try {
        Write-Log "Attempting to uninstall Netskope client..."
        Stop-NetskopeServices | Out-Null

        if (-not (Test-NetskopeInstalled)) {
            Write-Log "Netskope client was not found on this machine. Nothing to uninstall."
            return
        }

        $uninstallInfo = Get-NetskopeUninstallInfo

        if (-not $uninstallInfo) {
            Write-Log "Netskope appears to be installed (found $script:NetskopeInstallFolder) but no registry uninstall entry could be found, so an automated uninstall command cannot be determined. Manual removal or an action from the Netskope admin console is required."
            return
        }

        Write-Log "Found Netskope entry: $($uninstallInfo.DisplayName)"
        $uninstallString = $uninstallInfo.UninstallString

        # Step 1: simple uninstall, no password
        Write-Log "Step 1: attempting a simple uninstall (no password)."
        $exitCode = Invoke-NetskopeUninstaller -UninstallString $uninstallString -NetskopeDisablePassword ""
        Start-Sleep -Seconds 15

        if ($exitCode -eq 0 -and -not (Test-NetskopeInstalled)) {
            Write-Log "Netskope client uninstalled successfully on the first attempt."
            return
        }

        Write-Log "Simple uninstall did not remove the client (exit code: $exitCode). This is consistent with tamper protection / enforcement being enabled."
        Write-TamperProtectionGuidance

        if ([string]::IsNullOrWhiteSpace($NetskopeDisablePassword)) {
            Write-Log "No disable password is configured, so a retry cannot be attempted. Uninstall failed - see guidance above."
            return
        }

        # Step 2: retry once with the configured disable password
        Write-Log "Step 2: retrying uninstall with the configured disable password."
        $exitCode2 = Invoke-NetskopeUninstaller -UninstallString $uninstallString -NetskopeDisablePassword $NetskopeDisablePassword
        Start-Sleep -Seconds 15

        if ($exitCode2 -eq 0 -and -not (Test-NetskopeInstalled)) {
            Write-Log "Netskope client uninstalled successfully after retrying with the disable password."
        } else {
            Write-Log "Netskope client is still present after retrying with the disable password (exit code: $exitCode2)."
            Write-Log "Either the configured password is incorrect, or removal requires an action from the Netskope admin console. See guidance above."
        }
    } catch {
        Write-Log "Error uninstalling Netskope client: $_"
        if (Test-LooksLikeTamperProtection -errorText "$_") {
            Write-TamperProtectionGuidance
        }
        exit 1
    }
}
