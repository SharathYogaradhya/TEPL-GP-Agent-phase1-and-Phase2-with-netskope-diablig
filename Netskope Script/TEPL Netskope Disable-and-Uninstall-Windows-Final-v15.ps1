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

# --- Netskope functions (inlined starting in v15) -------------------------
# Previously these lived in a separate dot-sourced file
# (Netskope-Functions-v14.ps1 and earlier), which meant this script would
# fail at startup with "not found at path" if that second file wasn't
# copied to the exact expected location, and meant tracking two files'
# version numbers together. Folded directly into this script instead, so
# it is fully self-contained - no second file to place, no version pairing
# to keep straight. Functionally identical to Netskope-Functions-v14.ps1.
#
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

# Polls until Netskope is confirmed removed or the wait window expires,
# rather than checking once after a single fixed sleep. A successful
# (exit code 0) msiexec uninstall does not guarantee Netskope's own
# cleanup (folder removal, registry entry removal) has finished by the
# time msiexec.exe returns - real-machine testing showed this can lag
# behind a genuinely successful uninstall by more than 15 seconds.
function Wait-ForNetskopeRemoved {
    param (
        [int]$MaxWaitSeconds = 90,
        [int]$PollIntervalSeconds = 15
    )

    $elapsed = 0
    while ($elapsed -le $MaxWaitSeconds) {
        if (-not (Test-NetskopeInstalled)) {
            return $true
        }
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }

    return -not (Test-NetskopeInstalled)
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
        $removed = Wait-ForNetskopeRemoved

        if ($exitCode -eq 0 -and $removed) {
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
        $removed2 = Wait-ForNetskopeRemoved

        if ($exitCode2 -eq 0 -and $removed2) {
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
# --- End inlined Netskope functions ---------------------------------------

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
