# Determine the package root dynamically from this script's own location,
# instead of hardcoding "C:\PaloAlto Package\...". This script always lives
# at <PackageRoot>\Phase2 Script\<this file>, so the parent of this script's
# own folder is the package root - this works no matter what the top-level
# folder is named (e.g. "PaloAlto Package Phase2") or where it's placed
# (a fixed path, an Intune-extracted temp folder, anywhere). Removes the
# need for a deployment step to copy/rename the folder to a specific path
# before running this script.
$packageRoot = Split-Path -Parent $PSScriptRoot

# Define the log file path
$logFilePath = Join-Path $packageRoot "Installation Logs\PANW-Phase2-Logs.txt"

# Function to log messages
#
# Changed in v24: Write-Output -> Write-Host. Write-Output puts its string
# onto the CALLING function's own return pipeline, not just the console. Any
# function that calls Write-Log one or more times before returning a
# $true/$false therefore doesn't actually return a clean boolean - it returns
# an array of [log strings..., real boolean]. PowerShell's truthiness rule for
# arrays is: 0 elements = false, 1 element = that element's own truthiness,
# 2+ elements = ALWAYS true, regardless of contents. Test-GlobalProtectConnected
# calls Write-Log at least twice before returning, so `if (Test-GlobalProtectConnected ...)`
# at the bottom of this script was unconditionally true on every run - the
# "else" branch (skip Netskope handling because GlobalProtect isn't
# connected) was dead code, 100% unreachable, regardless of actual tunnel
# state. Confirmed on a real customer run on 2026-09-24: the log showed
# "Could not confirm GlobalProtect is connected ... within 300 seconds."
# immediately followed by "Attempting to uninstall Netskope client..." -
# Netskope was removed with no working GlobalProtect tunnel, leaving the
# device with neither. Reproduced directly against the real, unmodified
# v23 Test-GlobalProtectConnected function (not a rewritten copy) before
# this fix, and confirmed both outcomes (connected/not connected) branch
# correctly after it. Write-Host writes straight to the console without
# entering the pipeline at all, so it can no longer contaminate a caller's
# return value - it still displays live and still reaches the log file via
# Add-Content below, unchanged.
function Write-Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Write-Host $logMessage
    Add-Content -Path $logFilePath -Value $logMessage
}

# Function to check if the script is running as administrator
function Test-Administrator {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Function to install certificates
#
# Changed in v16: installs the Prelogon Root CA certificate (to the Trusted
# Root store) and the Prelogon Machine certificate (to the Personal "My"
# store, at both LocalMachine and CurrentUser) needed for GlobalProtect
# Prelogon machine-certificate authentication. GlobalProtect fetches the
# cert from the machine (LocalMachine) store during the prelogon stage;
# CurrentUser is also populated for consistency. The Machine certificate
# must be a .pfx (cert + private key) - a combined cert+encrypted-key .pem
# was tested directly against this same X509Certificate2 constructor and
# loaded with HasPrivateKey = False (no error, but the private key is
# silently dropped), so a plain .pem/.der export cannot be used for it.
# Also removes the dead, never-functional personalCertFilePath parameter
# (it was commented out of this param block already, so passing it at the
# call site was always silently ignored - see the Phase1 v3 changelog for
# why that's harmless rather than an error).
function Install-Certificates {
    param (
        [string]$trustedRootCertFilePath,
        [string]$decryptionCertFilePath,
        [string]$secondDecryptionCertFilePath, # New parameter for the second decryption certificate
        [string]$certPassword,
        [string]$preLogonCARootCertFilePath,
        [string]$preLogonMachineCertFilePath,
        [string]$preLogonMachineCertPassword
    )

    try {
        Write-Log "Installing certificates..."

        # Helper function to check if a certificate is already installed
        function Is-CertInstalled {
            param (
                [string]$thumbprint,
                [string]$storeName,
                [string]$storeLocation
            )

            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, $storeLocation)
            $store.Open("ReadOnly")
            $cert = $store.Certificates | Where-Object { $_.Thumbprint -eq $thumbprint }
            $store.Close()
            return $cert -ne $null
        }

        # Install certificate function
        function Install-Cert {
            param (
                [string]$certFilePath,
                [string]$storeName,
                [string]$storeLocation,
                [string]$certPassword
            )

            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certFilePath, $certPassword)
            if (-not (Is-CertInstalled -thumbprint $cert.Thumbprint -storeName $storeName -storeLocation $storeLocation)) {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, $storeLocation)
                $store.Open("ReadWrite")
                $store.Add($cert)
                $store.Close()
                Write-Log "Certificate with thumbprint $($cert.Thumbprint) installed successfully in $storeName store ($storeLocation)."
            } else {
                Write-Log "Certificate with thumbprint $($cert.Thumbprint) already exists in $storeName store ($storeLocation)."
            }
        }

        # Check if certificate files exist
        if (-Not (Test-Path -Path $trustedRootCertFilePath)) {
            Write-Log "Trusted Root certificate file not found at path: $trustedRootCertFilePath"
            throw "Trusted Root certificate file not found."
        }
        if (-Not (Test-Path -Path $decryptionCertFilePath)) {
            Write-Log "Decryption certificate file not found at path: $decryptionCertFilePath"
            throw "Decryption certificate file not found."
        }
        if (-Not (Test-Path -Path $secondDecryptionCertFilePath)) {
            Write-Log "Second decryption certificate file not found at path: $secondDecryptionCertFilePath"
            throw "Second decryption certificate file not found."
        }
        if (-Not (Test-Path -Path $preLogonCARootCertFilePath)) {
            Write-Log "Prelogon Root CA certificate file not found at path: $preLogonCARootCertFilePath"
            throw "Prelogon Root CA certificate file not found."
        }
        if (-Not (Test-Path -Path $preLogonMachineCertFilePath)) {
            Write-Log "Prelogon Machine certificate file not found at path: $preLogonMachineCertFilePath"
            throw "Prelogon Machine certificate file not found."
        }

        # Install trusted root certificate to Trusted Root store
        Install-Cert -certFilePath $trustedRootCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $null

        # Install decryption certificate to Trusted Root store
        Install-Cert -certFilePath $decryptionCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $certPassword

        # Install second decryption certificate to Trusted Root store
        Install-Cert -certFilePath $secondDecryptionCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $certPassword

        # Install Prelogon Root CA certificate to Trusted Root store (no private key)
        Install-Cert -certFilePath $preLogonCARootCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $null

        # Install Prelogon Machine certificate (with private key) to the Personal
        # store at both LocalMachine and CurrentUser - GlobalProtect fetches it
        # from the machine store during the prelogon stage.
        Install-Cert -certFilePath $preLogonMachineCertFilePath -storeName "My" -storeLocation "LocalMachine" -certPassword $preLogonMachineCertPassword
        Install-Cert -certFilePath $preLogonMachineCertFilePath -storeName "My" -storeLocation "CurrentUser" -certPassword $preLogonMachineCertPassword

    } catch {
        Write-Log "Error installing certificates: $_"
        exit 1
    }
}


# Returns $true if a GlobalProtect uninstall registry entry can be found.
# Replaces the Get-WmiObject Win32_Product check used through v17: Win32_Product
# is a known slow, deprecated WMI class whose enumeration has the side effect
# of triggering a repair-install scan of every MSI-installed application on
# the machine. This is the same fix already applied to Phase1 (v3+) - Phase2
# had its own separate copy of Install-GlobalProtect that never got it.
function Test-GlobalProtectInstalled {
    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($keyPath in $uninstallKeys) {
        $entry = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*GlobalProtect*" }
        if ($entry) {
            return $true
        }
    }

    return $false
}

# Polls a named condition (a script block returning $true/$false) instead of
# a single fixed sleep. Same helper already used in Phase1 (v3+).
function Wait-ForCondition {
    param (
        [scriptblock]$Condition,
        [int]$MaxWaitSeconds = 60,
        [int]$PollIntervalSeconds = 5
    )

    $elapsed = 0
    while ($elapsed -le $MaxWaitSeconds) {
        if (& $Condition) {
            return $true
        }
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }

    return & $Condition
}

# Ensures a registry key exists before writing a value to it. Set-ItemProperty
# cannot create a missing key - it only sets a value on a key that already
# exists. A real-machine test (2026-09-22) showed the HKCU GlobalProtect key
# not existing (GlobalProtect was already installed on that machine, but this
# user account had apparently never actually launched it - the per-user HKCU
# key is created by the running client, not by the MSI installer), so
# Set-ItemProperty threw "Cannot find path... because it does not exist." As a
# non-terminating error, the script did not stop - it printed the error and
# then logged "configured" right after anyway, which was false: the value was
# never actually set for that user.
function Set-RegistryValueEnsuringKeyExists {
    param (
        [string]$Path,
        [string]$Name,
        $Value
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value
}

# Function to install GlobalProtect and configure settings
#
# Changed in v18:
# - Replaced the Get-WmiObject Win32_Product "already installed" check with
#   Test-GlobalProtectInstalled (registry-based), matching Phase1 v3+.
# - The MSI install now captures and checks its own exit code, and polls for
#   the registry entry to appear instead of a fixed 45-second sleep, matching
#   Phase1 v2/v3.
# - All 4 registry writes (HKCU Portal/Prelogon, HKLM Portal/Prelogon) now go
#   through Set-RegistryValueEnsuringKeyExists, which creates the key first if
#   it's missing - see that function's comment for the real-machine failure
#   this fixes.
# - Restart-Service now uses -ErrorAction Stop and polls for the service to
#   actually reach Running, matching Phase1 v3/v4.
function Install-GlobalProtect {
    param (
        [string]$GlobalProtectInstallerPath,
        [string]$portal_fqdn
    )

    try {
        Write-Log "Installing and configuring GlobalProtect..."

        if (Test-GlobalProtectInstalled) {
            Write-Log "GlobalProtect is already installed. Skipping installation."
        } else {
            # Run the GlobalProtect installer silently, capturing its exit code
            $proc = Start-Process msiexec.exe -ArgumentList "/i `"$GlobalProtectInstallerPath`" /quiet /norestart" -Wait -PassThru

            if ($proc.ExitCode -ne 0) {
                Write-Log "GlobalProtect installer failed (msiexec exit code: $($proc.ExitCode)). Installation did not complete successfully."
                throw "GlobalProtect MSI install failed with exit code $($proc.ExitCode)."
            }

            if (Wait-ForCondition -Condition { Test-GlobalProtectInstalled } -MaxWaitSeconds 60 -PollIntervalSeconds 5) {
                Write-Log "GlobalProtect installed successfully (msiexec exit code: 0, registry entry confirmed)."
            } else {
                Write-Log "msiexec reported success (exit code 0), but no GlobalProtect registry entry was found within 60 seconds of waiting. Proceeding, but this is unexpected."
            }
        }

        # Set the registry key paths for the current user
        $userLevelPortalRegistryPath = "HKCU:\SOFTWARE\Palo Alto Networks\GlobalProtect"
        $userLevelPreLogonRegistryPath = "HKCU:\SOFTWARE\Palo Alto Networks\GlobalProtect"
        $portalRegistryValueName = "Portal"
        $preLogonRegistryValueName = "Prelogon"

        # Update the registry value to preconfigure the portal FQDN at the user level
        Set-RegistryValueEnsuringKeyExists -Path $userLevelPortalRegistryPath -Name $portalRegistryValueName -Value $portal_fqdn
        Write-Log "User level portal FQDN configured."

        # Update the registry value to enable pre-logon at the user level
        Set-RegistryValueEnsuringKeyExists -Path $userLevelPreLogonRegistryPath -Name $preLogonRegistryValueName -Value 1
        Write-Log "User level pre-logon enabled."

        # Set the registry key paths for the machine level
        $machineLevelPortalRegistryPath = "HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect\PanSetup"
        $machineLevelPreLogonRegistryPath = "HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect\PanSetup"

        # Update the registry value to preconfigure the portal FQDN at the machine level
        Set-RegistryValueEnsuringKeyExists -Path $machineLevelPortalRegistryPath -Name $portalRegistryValueName -Value $portal_fqdn
        Write-Log "Machine level portal FQDN configured."

        # Update the registry value to enable pre-logon at the machine level
        Set-RegistryValueEnsuringKeyExists -Path $machineLevelPreLogonRegistryPath -Name $preLogonRegistryValueName -Value 1
        Write-Log "Machine level pre-logon enabled."

        # Restart the GlobalProtect service to apply changes
        Restart-Service -Name PanGPS -Force -ErrorAction Stop

        if (Wait-ForCondition -Condition { (Get-Service -Name PanGPS -ErrorAction SilentlyContinue).Status -eq "Running" } -MaxWaitSeconds 60 -PollIntervalSeconds 5) {
            Write-Log "GlobalProtect configured and service restarted successfully, confirmed Running."
        } else {
            Write-Log "GlobalProtect service (PanGPS) did not reach Running status within 60 seconds of restarting. It may need more time or a manual check."
        }
    } catch {
        Write-Log "Error installing or configuring GlobalProtect: $_"
        exit 1
    }
}

# Returns $true if the given IPv4 address falls within the given CIDR
# range (e.g. "10.173.0.0/16"). Used to confirm a tunnel IP actually
# belongs to the known GlobalProtect assignment range, not just any
# non-link-local address.
function Test-IPInCidrRange {
    param (
        [string]$IPAddress,
        [string]$Cidr
    )

    $cidrParts = $Cidr -split '/'
    $networkIp = [System.Net.IPAddress]::Parse($cidrParts[0])
    $prefixLength = [int]$cidrParts[1]

    $ip = [System.Net.IPAddress]::Parse($IPAddress)
    $ipBytes = $ip.GetAddressBytes()
    $networkBytes = $networkIp.GetAddressBytes()

    $maskBytes = New-Object byte[] 4
    for ($i = 0; $i -lt 4; $i++) {
        $bitsRemaining = $prefixLength - ($i * 8)
        if ($bitsRemaining -ge 8) {
            $maskBytes[$i] = 255
        } elseif ($bitsRemaining -le 0) {
            $maskBytes[$i] = 0
        } else {
            $maskBytes[$i] = [byte](256 - [math]::Pow(2, 8 - $bitsRemaining))
        }
    }

    for ($i = 0; $i -lt 4; $i++) {
        if (($ipBytes[$i] -band $maskBytes[$i]) -ne ($networkBytes[$i] -band $maskBytes[$i])) {
            return $false
        }
    }

    return $true
}

# Returns the GlobalProtect tunnel IPv4 address if it is connected right now
# (a single, immediate check - no polling/waiting), or $null if not: service
# running, virtual adapter up, and its IP within the confirmed tunnel range.
# New in v21, factored out of Test-GlobalProtectConnected so the same
# signal-check logic can be reused for a single-shot check (see
# Start-GlobalProtectClientForUser below) without misusing that function's
# polling loop or its Netskope-specific log message.
function Test-GlobalProtectConnectedNow {
    param (
        [string]$GPTunnelSubnetCidr = "10.173.0.0/16"
    )

    $service = Get-Service -Name "PanGPS" -ErrorAction SilentlyContinue
    if (-not ($service -and $service.Status -eq "Running")) {
        return $null
    }

    $gpAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -like "*GlobalProtect*" -or $_.InterfaceDescription -like "*PANGP*" } |
        Select-Object -First 1

    if (-not $gpAdapter -or $gpAdapter.Status -ne "Up") {
        return $null
    }

    $ipInfo = Get-NetIPAddress -InterfaceIndex $gpAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { Test-IPInCidrRange -IPAddress $_.IPAddress -Cidr $GPTunnelSubnetCidr } |
        Select-Object -First 1

    if ($ipInfo) {
        return $ipInfo.IPAddress
    }
    return $null
}

# New in v19: launches the GlobalProtect client app (PanGPA.exe) in the
# logged-on interactive user's own desktop session.
#
# Real-machine field report (2026-09-22): on a machine where GlobalProtect
# was pre-installed by IT (not via this script) and the user had never
# actually opened it, Phase2 configured the Portal/Prelogon registry values
# correctly and restarted the PanGPS service - but the user still had to
# manually open GlobalProtect and click Connect. They confirmed the Portal
# field was already correctly populated (no typing needed), so the registry
# config was right; what was missing was the client app itself ever running.
# Restart-Service only restarts the PanGPS background service - it does not
# launch PanGPA.exe (the tray/UI process a user actually interacts with),
# and without that process running there is nothing to read our config and
# initiate a connection.
#
# Changed in v21: v19 skipped this whole function if PanGPA was already
# running, on the assumption that an already-running client had nothing
# left to do. Real-machine testing showed that assumption was wrong: v19
# did get the client running with the Portal field correctly pre-filled,
# but it still required a manual Connect click. A prior, separate project
# had already hit and solved exactly this - GlobalProtect reads its
# Portal/Prelogon configuration from the registry at its own process
# startup, not continuously, so an instance that was already running
# *before* Install-GlobalProtect wrote the current registry values keeps
# using whatever (or nothing) it read before, and never picks up the fresh
# config without being restarted. The fix confirmed on that prior project:
# restart the client after writing the registry, and it connects
# automatically (assuming the Portal's Connect Method is a real Always On
# mode) instead of waiting on a click. v21 always relaunches PanGPA via a
# temporary Scheduled Task (LogonType Interactive, registered to the
# logged-on user), run once and removed immediately after.
#
# Changed in v23, REVERTED in v25: v23 introduced Test-RunningAsSystem and
# switched this to a direct Stop-Process + Start-Process for any non-SYSTEM
# context (i.e. an admin running this interactively), on the theory that a
# UAC-elevated process already lands in the same session as the logged-on
# user, so the Scheduled Task indirection was unnecessary - based on a claim
# from a different, unrelated prior project that direct-restart was the
# mechanism actually proven to work there.
#
# Real-machine testing on THIS project on 2026-09-24 showed that claim does
# not hold here: with v23/v24 (direct Stop-Process + Start-Process), the
# customer confirmed GlobalProtect's Always On never auto-triggered - the
# client relaunched with the Portal field correctly pre-filled but sat on
# "Not Connected" waiting for a manual click, even after a confirmed-working
# manual connect/disconnect cycle. The customer also confirmed auto-connect
# DID work on an earlier version of this script (v21/v22, Scheduled Task for
# every case) before v23's change. The likely mechanism: Start-Process from
# an elevated PowerShell session typically inherits that elevation, so
# PanGPA.exe run this way ends up at High integrity (elevated) - whereas a
# Scheduled Task with LogonType Interactive launches it at the user's normal,
# non-elevated integrity level, exactly like double-clicking the icon.
# GlobalProtect's Always On / user-session detection appears not to treat an
# elevated instance the same as a normal one.
#
# v25 reverts to v21/v22's behavior: always launch/relaunch PanGPA via the
# Scheduled Task mechanism, regardless of whether this script itself is
# running as SYSTEM or interactively as an elevated admin. Test-RunningAsSystem
# is removed - it's no longer needed now that both contexts use the same path.
#
# Restarts PanGPA whenever it is running but not already connected, instead
# of leaving it alone - but only after confirming the client executable
# exists and a logged-on user can be identified, so an already-running (even
# if stale) client is never killed unless we can actually relaunch it. If
# GlobalProtect is already connected, this leaves it running untouched
# rather than disrupting a working session.
function Start-GlobalProtectClientForUser {
    param (
        [string]$GlobalProtectClientPath = "C:\Program Files\Palo Alto Networks\GlobalProtect\PanGPA.exe"
    )

    try {
        $existingTunnelIp = Test-GlobalProtectConnectedNow
        if ($existingTunnelIp) {
            Write-Log "GlobalProtect is already connected (tunnel IP $existingTunnelIp). Leaving the running client alone."
            return $true
        }

        if (-not (Test-Path -Path $GlobalProtectClientPath)) {
            Write-Log "GlobalProtect client executable not found at $GlobalProtectClientPath. Cannot launch/restart it automatically - the user will need to open GlobalProtect manually (the Portal is already configured, so no typing should be needed)."
            return $false
        }

        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $loggedOnUser = $computerSystem.UserName

        if ([string]::IsNullOrWhiteSpace($loggedOnUser)) {
            Write-Log "Could not determine a logged-on interactive user (no one may be logged on yet). Skipping automatic GlobalProtect client launch - it will need to be opened manually, or this will resolve itself the next time someone logs on interactively."
            return $false
        }

        $existingProcess = Get-Process -Name "PanGPA" -ErrorAction SilentlyContinue
        if ($existingProcess) {
            Write-Log "GlobalProtect client (PanGPA.exe) is running but not connected - restarting it so it picks up the current Portal/Prelogon registry configuration."
            Stop-Process -Name "PanGPA" -Force -ErrorAction SilentlyContinue
            Wait-ForCondition -Condition { -not (Get-Process -Name "PanGPA" -ErrorAction SilentlyContinue) } -MaxWaitSeconds 15 -PollIntervalSeconds 3 | Out-Null
        }

        Write-Log "Launching GlobalProtect client for logged-on user '$loggedOnUser' via a temporary Scheduled Task..."

        $taskName = "TEPL-Temp-Launch-GlobalProtect"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction -Execute $GlobalProtectClientPath
        $principal = New-ScheduledTaskPrincipal -UserId $loggedOnUser -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        if (Wait-ForCondition -Condition { Get-Process -Name "PanGPA" -ErrorAction SilentlyContinue } -MaxWaitSeconds 30 -PollIntervalSeconds 5) {
            Write-Log "GlobalProtect client launched successfully for user '$loggedOnUser'."
        } else {
            Write-Log "GlobalProtect client launch task ran, but PanGPA.exe was not confirmed running within 30 seconds. The user may need to open GlobalProtect manually."
        }

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-Log "Could not launch/restart GlobalProtect client for the interactive user: $_. The user may need to open GlobalProtect manually once (the Portal is already configured, so no typing should be needed)."
        return $false
    }
}

# Function to verify GlobalProtect is actually connected before we touch
# Netskope at all. Netskope is the user's only fallback connectivity until
# this is confirmed, so we do not disable or uninstall it on a guess.
#
# Requires three signals, not two: the PanGPS service running and the
# virtual adapter showing "Up" are not enough on their own - the adapter
# can report Up before the tunnel finishes authenticating, since PanGPS
# runs regardless of connection state. GlobalProtect only assigns a
# tunnel IPv4 address from a known range once a connection succeeds, so
# also requiring the adapter's IP to fall within that confirmed range
# (rather than just excluding link-local addresses) is a precise,
# environment-specific signal that the tunnel is actually established.
#
# Changed in v21: the actual signal-check logic now lives in
# Test-GlobalProtectConnectedNow (shared with Start-GlobalProtectClientForUser
# above); this function is unchanged in behavior, just polls that shared
# check instead of repeating the same inline logic.
function Test-GlobalProtectConnected {
    param (
        [int]$MaxWaitSeconds = 120,
        [int]$PollIntervalSeconds = 10,
        [string]$GPTunnelSubnetCidr = "10.173.0.0/16"
    )

    Write-Log "Verifying GlobalProtect is connected before making any changes to Netskope (will wait up to $MaxWaitSeconds seconds)..."

    $elapsed = 0
    while ($elapsed -le $MaxWaitSeconds) {
        $tunnelIp = Test-GlobalProtectConnectedNow -GPTunnelSubnetCidr $GPTunnelSubnetCidr
        if ($tunnelIp) {
            Write-Log "GlobalProtect service is running, the virtual adapter is up, and it has a tunnel IP address ($tunnelIp) within the confirmed range ($GPTunnelSubnetCidr). Treating GlobalProtect as connected."
            return $true
        }

        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }

    Write-Log "Could not confirm GlobalProtect is connected (service running + virtual adapter up + tunnel IP within $GPTunnelSubnetCidr) within $MaxWaitSeconds seconds."
    return $false
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
#
# Changed in v22: removed the initial no-password attempt entirely. The
# customer confirmed tamper protection enforcement is always active in this
# environment and the disable password is always required - identical for
# every user and device - so a no-password attempt was guaranteed to fail
# on every single deployment. That doomed attempt still cost real time on
# every run (the msiexec call itself, plus the ~90-second
# Wait-ForNetskopeRemoved poll that followed it) before ever reaching the
# password-based attempt that could actually work. This goes straight to
# the password-based uninstall as the only attempt.
#
# Still verified by re-checking whether Netskope is actually gone rather
# than trusting the uninstaller's exit code, and still checks for the same
# stuck/partially-uninstalled state introduced in v20 (Windows Installer
# registration stripped while files/services remain) - tamper protection
# blocking a password-included attempt mid-transaction is just as possible
# as it was for the no-password attempt.
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

        if ([string]::IsNullOrWhiteSpace($NetskopeDisablePassword)) {
            Write-Log "No disable password is configured, and this tenant is confirmed to always enforce tamper protection - an uninstall attempt without one cannot succeed. Set `$netskopeDisablePassword before re-running."
            return
        }

        Write-Log "Attempting uninstall with the configured disable password (tamper protection enforcement is confirmed always active in this environment, so the no-password attempt is skipped)."
        $exitCode = Invoke-NetskopeUninstaller -UninstallString $uninstallString -NetskopeDisablePassword $NetskopeDisablePassword
        $removed = Wait-ForNetskopeRemoved

        if ($exitCode -eq 0 -and $removed) {
            Write-Log "Netskope client uninstalled successfully."
            return
        }

        Write-Log "Uninstall did not remove the client (exit code: $exitCode)."
        Write-TamperProtectionGuidance

        # Same stuck/partially-uninstalled state introduced in v20: tamper
        # protection can strip the Windows Installer registration while
        # still blocking the actual removal of files/services mid-
        # transaction, leaving the client present but no longer considered
        # "installed" by Windows Installer.
        $stillRegistered = Get-NetskopeUninstallInfo
        if (-not $stillRegistered -and (Test-Path -Path $script:NetskopeInstallFolder)) {
            Write-Log "Netskope's Windows Installer registration is now gone, but its files/services are still present at $script:NetskopeInstallFolder - this is a partial, stuck uninstall left behind by tamper protection blocking the removal mid-transaction. This requires either a fresh uninstall attempt after the Netskope admin fully disables tamper protection for this device, or a manual/admin-console-driven cleanup of the leftover files and services."
            return
        }

        Write-Log "Netskope client is still present after the uninstall attempt (exit code: $exitCode)."
        Write-Log "This could mean the configured password no longer matches this tenant's disable password, or removal requires an action from the Netskope admin console. See guidance above."
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

# Define variables - all resolved relative to $packageRoot (computed at the
# top of this script from its own location), not a hardcoded fixed path.
$trustedRootCertFilePath = Join-Path $packageRoot "Certificates\TEPL-Root-CA.pem"
$decryptionCertFilePath = Join-Path $packageRoot "Certificates\Forward-Trust-CA.pem"
$secondDecryptionCertFilePath = Join-Path $packageRoot "Certificates\Forward-Trust-CA-ECDSA.pem"
$certPassword = "123456789"
$GlobalProtectInstallerPath = Join-Path $packageRoot "Installation File\GlobalProtect64.msi"
$portal_fqdn = "tepl.gpcloudservice.com"

# Prelogon Root CA + Machine certificate, needed for GlobalProtect Prelogon
# machine-certificate authentication. The Machine cert must be a .pfx (cert +
# private key) - see the Install-Certificates function comment for why a
# plain .pem/.der export cannot be used for it.
$preLogonCARootCertFilePath = Join-Path $packageRoot "Certificates\TEPL-PreLogon-CA.pem"
$preLogonMachineCertFilePath = Join-Path $packageRoot "Certificates\TEPL-PreLogon-MachineCert.pfx"
$preLogonMachineCertPassword = "123456789"

# Set to "Uninstall" to fully remove the Netskope client once GlobalProtect
# is confirmed connected (production decision), or "Disable" to stop and
# disable it without removing it instead.
$netskopeAction = "Uninstall"

# Real Netskope tenant disable/uninstall password, provided by the
# customer. Tamper protection is confirmed enabled for this tenant, so
# the plain (no-password) uninstall attempt is expected to fail and this
# password is what the retry step actually relies on - applied via the
# confirmed MSI PASSWORD property.
#
# Corrected in v12: the password is case-sensitive and was previously
# stored as "june@2026!@" (lowercase j). The real-machine test run on
# 2026-09-21 confirmed the password retry step failing with the same MSI
# exit code (1602) as the plain attempt, which pointed at the password
# itself rather than a deeper tamper-protection block - the customer then
# confirmed the correct casing is "June@2026!@" (capital J).
#
# Confirmed 2026-09-22: this same password is used org-wide, for every
# profile/user, not per-device - ruling out "wrong password for this
# device" as an explanation for any further uninstall failures. See the
# v20 changelog on Uninstall-NetskopeAgent for what that pointed to instead.
$netskopeDisablePassword = "June@2026!@"

# Install certificates (skips any certificate already present in the store)
Install-Certificates -trustedRootCertFilePath $trustedRootCertFilePath -decryptionCertFilePath $decryptionCertFilePath -secondDecryptionCertFilePath $secondDecryptionCertFilePath -certPassword $certPassword -preLogonCARootCertFilePath $preLogonCARootCertFilePath -preLogonMachineCertFilePath $preLogonMachineCertFilePath -preLogonMachineCertPassword $preLogonMachineCertPassword

# Install and configure GlobalProtect (skips install if already present, then
# configures Portal + Prelogon for automatic, no-user-interaction connection)
Install-GlobalProtect -GlobalProtectInstallerPath $GlobalProtectInstallerPath -portal_fqdn $portal_fqdn

# New in v19, changed in v21: launch (or restart, if already running but not
# connected) the GlobalProtect client app itself for the logged-on user.
# Configuring the Portal/Prelogon registry values and restarting the PanGPS
# background service is not enough to get an automatic connection if the
# client was already running before that registry write - see
# Start-GlobalProtectClientForUser's comment for the real-machine field
# reports (v19 and v21) behind this. This is best-effort: if it can't
# determine a logged-on user or find the client executable, it logs why and
# leaves any existing client alone rather than risk leaving the user with
# no running client at all.
Start-GlobalProtectClientForUser | Out-Null

# Only touch Netskope once GlobalProtect is confirmed connected. If we
# can't confirm it, leave Netskope alone so the user keeps a working
# fallback connection.
#
# Wait window raised from the 120s default to 300s (5 minutes): 120s is
# comfortable for certificate-based auto-connect, but is not necessarily
# enough time for a portal that requires interactive SAML/SSO login (with
# possible MFA) before the tunnel comes up. This has not yet been
# confirmed against the customer's actual auth flow, so the longer window
# is the safer default until that is verified on real hardware.
if (Test-GlobalProtectConnected -MaxWaitSeconds 300 -PollIntervalSeconds 10) {
    if ($netskopeAction -eq "Disable") {
        Disable-NetskopeAgent
    } else {
        Uninstall-NetskopeAgent -NetskopeDisablePassword $netskopeDisablePassword
    }
} else {
    Write-Log "Skipping Netskope disable/uninstall because GlobalProtect connectivity could not be verified. Netskope remains active as a fallback. Re-run this script once GlobalProtect is confirmed connected."
}

# Final notification to the user
Write-Log "Installation of the Prisma Access Global Protect agent is now complete. Netskope handling ran only if GlobalProtect connectivity was verified - see log above for the outcome."
Write-Output "Installation of the Prisma Access Global Protect agent is now complete. Netskope handling ran only if GlobalProtect connectivity was verified - see log above for the outcome."
