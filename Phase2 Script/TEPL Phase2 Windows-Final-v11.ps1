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

# Shared Netskope functions (v6): confirmed against real data collected
# from an actual Netskope-installed machine (service name stAgentSvc,
# MSI-based install, install folder) and official Netskope documentation
# (the PASSWORD MSI public property for the tamper-protection bypass).
# Disable-NetskopeAgent also disables any Netskope-related Scheduled
# Tasks and verifies the end state (service stopped + disabled) instead
# of assuming success. Uninstall-NetskopeAgent tries a plain uninstall
# first, then retries once with the configured password (applied via the
# confirmed PASSWORD property) only if the plain attempt did not remove
# the client.
$netskopeFunctionsPath = "C:\PaloAlto Package\Netskope Script\Netskope-Functions-v6.ps1"
if (-not (Test-Path -Path $netskopeFunctionsPath)) {
    Write-Log "Netskope-Functions-v6.ps1 not found at path: $netskopeFunctionsPath"
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
$netskopeDisablePassword = "june@2026!@"

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
