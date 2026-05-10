# Exchange Online — Certificate Setup Helper
# Generates a self-signed PFX certificate for app-only Exchange Online
# authentication and prints the public-key (.cer) blob you must upload
# to your Azure AD App Registration.
#
# This is a ONE-TIME bootstrap. After running it:
#   1. Upload the printed .cer file to Azure AD → App Registrations → <YourApp> → Certificates & secrets
#   2. Grant "Exchange.ManageAsApp" (Application) API permission and admin-consent
#   3. Assign the app to the "Exchange Administrator" directory role
#   4. Fill APP_ID / CERT_PFX_PATH / CERT_PFX_PASSWORD in .env and set AUTH_MODE=certificate
#
# This script does NOT create the Azure AD app — you do that in the portal.
# It also does NOT contact Exchange Online.

# ============================================
# LOAD CONFIGURATION FROM .ENV
# ============================================
$envFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $envFile)) {
    Write-Host "ERROR: .env file not found!" -ForegroundColor Red
    exit 1
}

Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        $key = $matches[1].Trim()
        $value = $matches[2].Trim()
        Set-Variable -Name $key -Value $value -Scope Script
    }
}

$tenantDomain = $TENANT_DOMAIN
if ([string]::IsNullOrWhiteSpace($tenantDomain)) {
    Write-Host "ERROR: TENANT_DOMAIN is not set in .env" -ForegroundColor Red
    exit 1
}

$certDir       = Join-Path $PSScriptRoot "certs"
$certBaseName  = "exo-app-$($tenantDomain.Replace('.', '-'))"
$pfxPath       = Join-Path $certDir "$certBaseName.pfx"
$cerPath       = Join-Path $certDir "$certBaseName.cer"
$friendlyName  = "ExchangeOnline App-Only ($tenantDomain)"
$validityYears = 2

if (-not (Test-Path $certDir)) {
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
}

if (Test-Path $pfxPath) {
    Write-Host "ERROR: $pfxPath already exists." -ForegroundColor Red
    Write-Host "Move/rename the existing certificate before regenerating." -ForegroundColor Yellow
    exit 1
}

# ============================================
# COLLECT PASSWORD
# ============================================
$pfxPassword = Read-Host -Prompt "Choose a PFX password (will be needed by Connect-ExchangeOnline)" -AsSecureString
$pfxPasswordConfirm = Read-Host -Prompt "Confirm PFX password" -AsSecureString

# Compare two SecureStrings safely
$bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pfxPassword)
$bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pfxPasswordConfirm)
$plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr1)
$plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
if ($plain1 -ne $plain2) {
    Write-Host "ERROR: Passwords do not match." -ForegroundColor Red
    exit 1
}
if ([string]::IsNullOrWhiteSpace($plain1)) {
    Write-Host "ERROR: Empty password is not allowed." -ForegroundColor Red
    exit 1
}

# ============================================
# GENERATE SELF-SIGNED CERTIFICATE (cross-platform via .NET APIs)
# ============================================
Write-Host "`nGenerating self-signed certificate ..." -ForegroundColor Cyan

$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    "CN=$friendlyName",
    $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

$req.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,
        $false
    )
)

$req.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new(
        $req.PublicKey, $false
    )
)

$notBefore = [System.DateTimeOffset]::UtcNow.AddMinutes(-5)
$notAfter  = $notBefore.AddYears($validityYears)
$cert      = $req.CreateSelfSigned($notBefore, $notAfter)

# ============================================
# EXPORT
# ============================================
$pfxBytes = $cert.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
    $plain1
)
[System.IO.File]::WriteAllBytes($pfxPath, $pfxBytes)

$cerBytes = $cert.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert
)
[System.IO.File]::WriteAllBytes($cerPath, $cerBytes)

# Tighten permissions on the private key (POSIX only)
if ($IsMacOS -or $IsLinux) {
    chmod 600 $pfxPath | Out-Null
}

# Wipe plaintext password from memory
$plain1 = $null
$plain2 = $null
[System.GC]::Collect()

# ============================================
# REPORT
# ============================================
Write-Host "`nCertificate generated:" -ForegroundColor Green
Write-Host "  Subject     : $($cert.Subject)"
Write-Host "  Thumbprint  : $($cert.Thumbprint)"
Write-Host "  Valid until : $($cert.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host "  PFX (private): $pfxPath" -ForegroundColor Yellow
Write-Host "  CER (public) : $cerPath" -ForegroundColor Yellow

Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "  1. Azure AD → App Registrations → New registration → 'ExchangeOnline-Automation'"
Write-Host "  2. Certificates & secrets → Upload certificate → choose: $cerPath"
Write-Host "  3. API permissions → Add → Office 365 Exchange Online → Application → Exchange.ManageAsApp → Grant admin consent"
Write-Host "  4. Roles and administrators → assign 'Exchange Administrator' to the app's service principal"
Write-Host "  5. Copy the App (client) ID into .env as APP_ID"
Write-Host "  6. Set in .env:"
Write-Host "       AUTH_MODE=certificate"
Write-Host "       APP_ID=<guid>"
Write-Host "       CERT_PFX_PATH=$pfxPath"
Write-Host "       CERT_PFX_PASSWORD=<the password you just chose>"
Write-Host "  7. Run any script — no browser, no MFA, no re-login between runs."
