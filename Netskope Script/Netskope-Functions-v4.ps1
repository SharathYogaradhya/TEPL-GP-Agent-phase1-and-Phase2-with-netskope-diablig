# Shared Netskope client functions (v4).
# Dot-source this file from a calling script (which must already define
# Write-Log) rather than importing it as a module, so these functions log
# to the calling script's own log file:
#   . "C:\PaloAlto Package\Netskope Script\Netskope-Functions-v4.ps1"
#
# Changes from v3 (Netskope-Functions-v3.ps1):
# - Disable-NetskopeAgent now also finds and disables any Scheduled Tasks
#   referencing Netskope, since a service set to Disabled can still be
#   relaunched at boot/logon by a separate scheduled task. Some agents
#   (Netskope included, depending on deployment) use one as a secondary
#   launch mechanism, so disabling only the service is not reliably
#   restart-proof on its own.
# - Disable-NetskopeAgent finishes with an explicit verification pass,
#   re-checking that each targeted service is both Stopped and Disabled,
#   and logs a clear pass/fail per service rather than assuming success.

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

# Returns $true if a Netskope client entry can still be found on the machine.
function Test-NetskopeInstalled {
    $defaultUninstallerPath = "C:\Program Files (x86)\Netskope\STAgent\unins000.exe"
    $info = Get-NetskopeUninstallInfo
    return ($null -ne $info) -or (Test-Path -Path $defaultUninstallerPath)
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
function Invoke-NetskopeUninstaller {
    param (
        [string]$UninstallString,
        [string]$NetskopeDisablePassword
    )

    if ($UninstallString -match "msiexec") {
        # MSI-based uninstall
        $productCode = [regex]::Match($UninstallString, "\{[0-9A-Fa-f\-]+\}").Value
        $arguments = "/x `"$productCode`" /quiet /norestart"
        Write-Log "Running MSI uninstall: msiexec.exe $arguments"
        $proc = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
    } else {
        # Inno Setup-based uninstaller (standard for Netskope client)
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
#         with the supplied disable password (treating the failure as a
#         likely tamper-protection block).
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
        $defaultUninstallerPath = "C:\Program Files (x86)\Netskope\STAgent\unins000.exe"

        if ($uninstallInfo) {
            Write-Log "Found Netskope entry: $($uninstallInfo.DisplayName)"
            $uninstallString = $uninstallInfo.UninstallString
        } else {
            Write-Log "Registry entry not found. Falling back to default uninstaller path."
            $uninstallString = $defaultUninstallerPath
        }

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
