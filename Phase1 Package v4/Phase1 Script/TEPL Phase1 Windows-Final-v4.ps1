# Define the log file path
$logFilePath = "C:\PaloAlto Package\Installation Logs\PANW-Phase1-Logs.txt"

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

        # Install decryption certificate to Trusted Root store
        Install-Cert -certFilePath $decryptionCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $certPassword

        # Install second decryption certificate to Trusted Root store
        Install-Cert -certFilePath $secondDecryptionCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $certPassword

    } catch {
        Write-Log "Error installing certificates: $_"
        exit 1
    }
}

# Returns $true if a GlobalProtect uninstall registry entry can be found.
# Replaces the Get-WmiObject Win32_Product check used through v2: Win32_Product
# is a known slow, deprecated WMI class whose enumeration has the side effect
# of triggering a repair-install scan of every MSI-installed application on
# the machine. This uses the same registry-uninstall-key pattern already
# proven for Netskope detection instead.
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
# a single fixed sleep. Used both to confirm the GlobalProtect registry entry
# actually appears after install, and to confirm the PanGPS service actually
# reaches the desired status after being restarted - purely local machine
# state, not GlobalProtect's network/tunnel connectivity (that check stays in
# Phase2, not here).
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

# Function to install GlobalProtect
#
# Changed in v4: Restart-Service now uses -ErrorAction Stop. Previously
# (v3), if the service somehow didn't exist at that point, Restart-Service
# would raise a non-terminating error - printed to the error stream but not
# caught by the surrounding try/catch, so the script would carry on past a
# real failure instead of hitting the catch block's error handling. Making
# it a terminating error means that failure is now caught and logged like
# every other failure path in this function.
#
# Changed in v3 (all local-machine-state checks - no GlobalProtect
# network/tunnel connectivity check here, that remains Phase2's job):
# - Replaced the Get-WmiObject Win32_Product "already installed" check with
#   Test-GlobalProtectInstalled (registry-based - avoids Win32_Product's
#   slowness and its side effect of triggering a repair scan of every
#   installed MSI package on the machine).
# - Replaced the fixed 45-second Start-Sleep after install with polling
#   Test-GlobalProtectInstalled (via Wait-ForCondition) for up to 60 seconds,
#   confirming the registry entry actually appeared instead of guessing a
#   wait time.
# - After Restart-Service, polls for the PanGPS service to actually reach
#   "Running" (via Wait-ForCondition, up to 60 seconds) instead of assuming
#   success right after the restart call returns.
#
# Carried over from v2: the msiexec install still captures and checks its
# own exit code instead of assuming success right after Start-Process
# returns.
function Install-GlobalProtect {
    param (
        [string]$GlobalProtectInstallerPath
    )

    try {
        Write-Log "Installing GlobalProtect..."

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

            # Restart the GlobalProtect service to apply changes
            Restart-Service -Name PanGPS -Force -ErrorAction Stop

            if (Wait-ForCondition -Condition { (Get-Service -Name PanGPS -ErrorAction SilentlyContinue).Status -eq "Running" } -MaxWaitSeconds 60 -PollIntervalSeconds 5) {
                Write-Log "GlobalProtect service (PanGPS) restarted and confirmed Running."
            } else {
                Write-Log "GlobalProtect service (PanGPS) did not reach Running status within 60 seconds of restarting. It may need more time or a manual check."
            }
        }
    } catch {
        Write-Log "Error installing or configuring GlobalProtect: $_"
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
$trustedRootCertFilePath = "C:\PaloAlto Package\Certificates\TEPL-Root-CA.pem"
$decryptionCertFilePath = "C:\PaloAlto Package\Certificates\Forward-Trust-CA.pem" # Adjust path as needed
$secondDecryptionCertFilePath = "C:\PaloAlto Package\Certificates\Forward-Trust-CA-ECDSA.pem" # Adjust path as needed
$certPassword = "123456789"
$GlobalProtectInstallerPath = "C:\PaloAlto Package\Installation File\GlobalProtect64.msi"

# Install certificates
Install-Certificates -trustedRootCertFilePath $trustedRootCertFilePath -decryptionCertFilePath $decryptionCertFilePath -secondDecryptionCertFilePath $secondDecryptionCertFilePath -certPassword $certPassword

# Install GlobalProtect
Install-GlobalProtect -GlobalProtectInstallerPath $GlobalProtectInstallerPath

# Final notification to the user
Write-Log "Installation of the Prisma Access Global Protect agent is now complete."
Write-Output "Installation of the Prisma Access Global Protect agent is now complete."
