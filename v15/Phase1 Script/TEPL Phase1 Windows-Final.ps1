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
        #}
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
      #  Install-Cert -certFilePath $personalCertFilePath -storeName "My" -storeLocation "CurrentUser" -certPassword $certPassword

        # Install decryption certificate to Trusted Root store
        Install-Cert -certFilePath $decryptionCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $certPassword

        # Install second decryption certificate to Trusted Root store
        Install-Cert -certFilePath $secondDecryptionCertFilePath -storeName "Root" -storeLocation "LocalMachine" -certPassword $certPassword

    } catch {
        Write-Log "Error installing certificates: $_"
        exit 1
    }
}

# Function to install GlobalProtect
function Install-GlobalProtect {
    param (
        [string]$GlobalProtectInstallerPath
    )

    try {
        Write-Log "Installing GlobalProtect..."

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
			# Restart the GlobalProtect service to apply changes
            Restart-Service -Name PanGPS -Force
            Write-Log "GlobalProtect service restarted successfully."
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
Install-Certificates -trustedRootCertFilePath $trustedRootCertFilePath -personalCertFilePath $personalCertFilePath -decryptionCertFilePath $decryptionCertFilePath -secondDecryptionCertFilePath $secondDecryptionCertFilePath -certPassword $certPassword

# Install GlobalProtect
Install-GlobalProtect -GlobalProtectInstallerPath $GlobalProtectInstallerPath

# Final notification to the user
Write-Log "Installation of the Prisma Access Global Protect agent is now complete."
Write-Output "Installation of the Prisma Access Global Protect agent is now complete."
