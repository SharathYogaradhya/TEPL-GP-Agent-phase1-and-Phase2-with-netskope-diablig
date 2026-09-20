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

# Function to verify GlobalProtect is actually connected before we touch
# Netskope at all. Netskope is the user's only fallback connectivity until
# this is confirmed, so we do not disable or uninstall it on a guess.
#
# Requires three signals, not two: the PanGPS service running and the
# virtual adapter showing "Up" are not enough on their own - the adapter
# can report Up before the tunnel finishes authenticating, since PanGPS
# runs regardless of connection state. GlobalProtect only assigns a real
# tunnel IPv4 address after a successful connection, so also requiring a
# non-link-local IPv4 address on that adapter is a meaningfully stronger
# signal that the tunnel is actually established, without needing to
# guess at any environment-specific internal resource to test against.
function Test-GlobalProtectConnected {
    param (
        [int]$MaxWaitSeconds = 120,
        [int]$PollIntervalSeconds = 10
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
                        Where-Object { $_.IPAddress -notlike "169.254.*" } |
                        Select-Object -First 1
                    $gpAdapterHasTunnelIp = [bool]$ipInfo
                    if ($ipInfo) { $tunnelIp = $ipInfo.IPAddress }
                }
            }
        }

        if ($serviceRunning -and $gpAdapterUp -and $gpAdapterHasTunnelIp) {
            Write-Log "GlobalProtect service is running, the virtual adapter is up, and it has a valid tunnel IP address ($tunnelIp). Treating GlobalProtect as connected."
            return $true
        }

        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }

    Write-Log "Could not confirm GlobalProtect is connected (service running + virtual adapter up + valid tunnel IP assigned) within $MaxWaitSeconds seconds."
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

# Set to "Disable" to stop and disable Netskope without removing it (default,
# matches the validated requirement: disable only once GP is confirmed
# connected, and make sure it stays stopped after a restart), or
# "Uninstall" to fully remove the Netskope client instead.
$netskopeAction = "Disable"

# PLACEHOLDER - only used when $netskopeAction is "Uninstall" and tamper
# protection is enabled. Replace with the real disable password from the
# Netskope tenant admin console (Settings > Client Configuration > General).
# The confirmed MSI PASSWORD property is applied automatically once this
# is set to the real value.
$netskopeDisablePassword = "DummyPassword123"

# Install certificates (skips any certificate already present in the store)
Install-Certificates -trustedRootCertFilePath $trustedRootCertFilePath -personalCertFilePath $personalCertFilePath -decryptionCertFilePath $decryptionCertFilePath -secondDecryptionCertFilePath $secondDecryptionCertFilePath -certPassword $certPassword

# Install and configure GlobalProtect (skips install if already present, then
# configures Portal + Prelogon for automatic, no-user-interaction connection)
Install-GlobalProtect -GlobalProtectInstallerPath $GlobalProtectInstallerPath -portal_fqdn $portal_fqdn

# Only touch Netskope once GlobalProtect is confirmed connected. If we
# can't confirm it, leave Netskope alone so the user keeps a working
# fallback connection.
if (Test-GlobalProtectConnected) {
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
