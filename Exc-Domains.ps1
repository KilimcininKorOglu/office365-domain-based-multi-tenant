# Exchange Online Accepted Domain Fetcher
# Connects to Exchange Online and writes all accepted domains to DOMAIN_LIST_FILE.

# ============================================
# LOAD CONFIGURATION FROM .ENV
# ============================================
$envFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $envFile)) {
    Write-Host "ERROR: .env file not found!" -ForegroundColor Red
    Write-Host "Copy .env.example to .env and configure your settings." -ForegroundColor Yellow
    exit 1
}

Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        $key = $matches[1].Trim()
        $value = $matches[2].Trim()
        Set-Variable -Name $key -Value $value -Scope Script
    }
}

$tenantDomain   = $TENANT_DOMAIN
$adminUser      = $ADMIN_USER
$domainListFile = $DOMAIN_LIST_FILE

if ([string]::IsNullOrWhiteSpace($adminUser)) {
    Write-Host "ERROR: ADMIN_USER is not set in .env" -ForegroundColor Red
    exit 1
}
if ([string]::IsNullOrWhiteSpace($domainListFile)) {
    Write-Host "ERROR: DOMAIN_LIST_FILE is not set in .env" -ForegroundColor Red
    exit 1
}

# ============================================
# MODULE SETUP
# ============================================
if ($IsWindows) {
    Set-ExecutionPolicy Unrestricted -Scope Process -Force
}
Install-Module -Name ExchangeOnlineManagement -RequiredVersion 3.0.0 -Force -AllowClobber
Import-Module ExchangeOnlineManagement

. (Join-Path $PSScriptRoot "_Exc-Connect.ps1")

# ============================================
# CONNECT TO EXCHANGE ONLINE
# ============================================
Connect-ExoSmart `
    -AdminUser        $adminUser `
    -TenantDomain     $tenantDomain `
    -AuthMode         $AUTH_MODE `
    -AppId            $APP_ID `
    -CertPfxPath      $CERT_PFX_PATH `
    -CertPfxPassword  $CERT_PFX_PASSWORD `
    -UseDeviceCode    $USE_DEVICE_CODE

# ============================================
# FETCH ACCEPTED DOMAINS
# ============================================
Write-Host "`nFetching accepted domains ..." -ForegroundColor Cyan

$acceptedDomains = Get-AcceptedDomain |
    Select-Object -ExpandProperty DomainName |
    Where-Object { $_ -ne $tenantDomain } |
    Sort-Object -Unique

if (-not $acceptedDomains -or $acceptedDomains.Count -eq 0) {
    Write-Host "No accepted domains returned (excluding tenant domain $tenantDomain)." -ForegroundColor Yellow
    Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
    exit 0
}

Write-Host "`nFound $($acceptedDomains.Count) domain(s):" -ForegroundColor Green
$acceptedDomains | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }

# ============================================
# WRITE TO DOMAIN LIST FILE
# ============================================
$targetDir = Split-Path -Parent $domainListFile
if ($targetDir -and -not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

if (Test-Path $domainListFile) {
    $backupFile = "$domainListFile.bak"
    Copy-Item -Path $domainListFile -Destination $backupFile -Force
    Write-Host "`nExisting file backed up to: $backupFile" -ForegroundColor Yellow
}

$acceptedDomains | Set-Content -Path $domainListFile -Encoding UTF8
Write-Host "`nDomain list written to: $domainListFile" -ForegroundColor Green

# ============================================
# DISCONNECT
# ============================================
Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
Write-Host "`nDone." -ForegroundColor Magenta
