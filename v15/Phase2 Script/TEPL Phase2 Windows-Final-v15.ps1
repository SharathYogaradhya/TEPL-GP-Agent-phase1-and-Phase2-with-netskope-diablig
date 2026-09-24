# Define the log file path
$logFilePath = "C:\PaloAlto Package\Installation Logs\PANW-Phase2-Logs.txt"

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

# Function to install certificates
function Install-Certificates {
    param (
        [string]$trustedRootCertFilePath,
        #[string]$personalCertFilePath,
        [string]$decryptionCertFilePath,
        [string]$secondDecryptionCertFilePath, # New parameter for the second decryption certificate
        [string]$certPassword
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
       # if (-Not (Test-Path -Path $personalCertFilePath)) {
        #    Write-Log "Personal certificate file not found at path: $personalCertFilePath"
         #   throw "Personal certificate file not found."
       # }
        if (-Not (Test-Path -Path $decryptionCertFilePath)) {
            Write-Log "Decryption certificate file not found at path: $decryptionCertFilePath"
            throw "Decryption certificate file not found."
        }
        if (-Not (Test-Path -Path $secondDecryptionCertFilePath)) {
            Write-Log "Second decryption certificate file not found at path: $secondDecryptionCertFilePath"
            throw "Second decryption certificate file not found."
        }

        # Install trusted root certificate to Trusted Root store
        Install-Cert -certFilePath $trustedRootCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $null

        # Install personal certificate to Personal store (LocalMachine)
       # Install-Cert -certFilePath $personalCertFilePath -storeName "My" -storeLocation "LocalMachine" -certPassword $certPassword

        # Install personal certificate to Personal store (CurrentUser)
       # Install-Cert -certFilePath $personalCertFilePath -storeName "My" -storeLocation "CurrentUser" -certPassword $certPassword

        # Install decryption certificate to Trusted Root store
        Install-Cert -certFilePath $decryptionCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $certPassword

        # Install second decryption certificate to Trusted Root store
        Install-Cert -certFilePath $secondDecryptionCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $certPassword

    } catch {
        Write-Log "Error installing certificates: $_"
        exit 1
    }
}


# Function to install GlobalProtect and configure settings
function Install-GlobalProtect {
    param (
        [string]$GlobalProtectInstallerPath,
        [string]$portal_fqdn
    )

    try {
        Write-Log "Installing and configuring GlobalProtect..."

        # Check if GlobalProtect is already installed
        $globalProtectInstalled = Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name = 'GlobalProtect'" | ForEach-Object {
            $_.Name -eq "GlobalProtect"
        }

        if ($globalProtectInstalled) {
            Write-Log "GlobalProtect is already installed. Skipping installation."
        } else {
            # Run the GlobalProtect installer silently
            Start-Process msiexec.exe -ArgumentList "/i `"$GlobalProtectInstallerPath`" /quiet /norestart" -Wait
            Start-Sleep -Seconds 45
            Write-Log "GlobalProtect installed successfully."
        }

        # Set the registry key paths for the current user
        $userLevelPortalRegistryPath = "HKCU:\SOFTWARE\Palo Alto Networks\GlobalProtect"
        $userLevelPreLogonRegistryPath = "HKCU:\SOFTWARE\Palo Alto Networks\GlobalProtect"
        $portalRegistryValueName = "Portal"
        $preLogonRegistryValueName = "Prelogon"

        # Update the registry value to preconfigure the portal FQDN at the user level
        Set-ItemProperty -Path $userLevelPortalRegistryPath -Name $portalRegistryValueName -Value $portal_fqdn
        Write-Log "User level portal FQDN configured."

        # Update the registry value to enable pre-logon at the user level
        Set-ItemProperty -Path $userLevelPreLogonRegistryPath -Name $preLogonRegistryValueName -Value 1
        Write-Log "User level pre-logon enabled."

        # Set the registry key paths for the machine level
        $machineLevelPortalRegistryPath = "HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect\PanSetup"
        $machineLevelPreLogonRegistryPath = "HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect\PanSetup"

        # Update the registry value to preconfigure the portal FQDN at the machine level
        Set-ItemProperty -Path $machineLevelPortalRegistryPath -Name $portalRegistryValueName -Value $portal_fqdn
        Write-Log "Machine level portal FQDN configured."

        # Update the registry value to enable pre-logon at the machine level
        Set-ItemProperty -Path $machineLevelPreLogonRegistryPath -Name $preLogonRegistryValueName -Value 1
        Write-Log "Machine level pre-logon enabled."

        # Restart the GlobalProtect service to apply changes
        Restart-Service -Name PanGPS -Force
        Write-Log "GlobalProtect configured and service restarted successfully."
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
function Test-GlobalProtectConnected {
    param (
        [int]$MaxWaitSeconds = 120,
        [int]$PollIntervalSeconds = 10,
        [string]$GPTunnelSubnetCidr = "10.173.0.0/16"
    )

    Write-Log "Verifying GlobalProtect is connected before making any changes to Netskope (will wait up to $MaxWaitSeconds seconds)..."

    $elapsed = 0
    while ($elapsed -le $MaxWaitSeconds) {
        $service = Get-Service -Name "PanGPS" -ErrorAction SilentlyContinue
        $serviceRunning = $service -and $service.Status -eq "Running"

        $gpAdapterUp = $false
        $gpAdapterHasTunnelIp = $false
        $tunnelIp = $null

        if ($serviceRunning) {
            $gpAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceDescription -like "*GlobalProtect*" -or $_.InterfaceDescription -like "*PANGP*" } |
                Select-Object -First 1

            if ($gpAdapter) {
                $gpAdapterUp = $gpAdapter.Status -eq "Up"

                if ($gpAdapterUp) {
                    $ipInfo = Get-NetIPAddress -InterfaceIndex $gpAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { Test-IPInCidrRange -IPAddress $_.IPAddress -Cidr $GPTunnelSubnetCidr } |
                        Select-Object -First 1
                    $gpAdapterHasTunnelIp = [bool]$ipInfo
                    if ($ipInfo) { $tunnelIp = $ipInfo.IPAddress }
                }
            }
        }

        if ($serviceRunning -and $gpAdapterUp -and $gpAdapterHasTunnelIp) {
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

# Define variables
$trustedRootCertFilePath = "C:\PaloAlto Package\Certificates\TEPL-Root-CA.pem"
$decryptionCertFilePath = "C:\PaloAlto Package\Certificates\Forward-Trust-CA.pem" # Adjust path as needed
$secondDecryptionCertFilePath = "C:\PaloAlto Package\Certificates\Forward-Trust-CA-ECDSA.pem" # Adjust path as needed
$certPassword = "123456789"
$GlobalProtectInstallerPath = "C:\PaloAlto Package\Installation File\GlobalProtect64.msi"
$portal_fqdn = "tepl.gpcloudservice.com"

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
$netskopeDisablePassword = "June@2026!@"

# Install certificates (skips any certificate already present in the store)
Install-Certificates -trustedRootCertFilePath $trustedRootCertFilePath -personalCertFilePath $personalCertFilePath -decryptionCertFilePath $decryptionCertFilePath -secondDecryptionCertFilePath $secondDecryptionCertFilePath -certPassword $certPassword

# Install and configure GlobalProtect (skips install if already present, then
# configures Portal + Prelogon for automatic, no-user-interaction connection)
Install-GlobalProtect -GlobalProtectInstallerPath $GlobalProtectInstallerPath -portal_fqdn $portal_fqdn

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
