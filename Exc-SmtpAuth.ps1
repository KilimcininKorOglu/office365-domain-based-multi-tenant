# Exchange Online — Enable Authenticated SMTP for All Mailboxes
# Sets SmtpClientAuthenticationDisabled = $false on every UserMailbox
# so users can send mail via SMTP AUTH (port 587).
#
# Prerequisites:
#   - Authenticated SMTP must be enabled at the organization level
#     (Set-TransportConfig -SmtpClientAuthenticationDisabled $false)
#   - This script enables it per-mailbox.

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
    -AdminUser        $ADMIN_USER `
    -TenantDomain     $TENANT_DOMAIN `
    -AuthMode         $AUTH_MODE `
    -AppId            $APP_ID `
    -CertPfxPath      $CERT_PFX_PATH `
    -CertPfxPassword  $CERT_PFX_PASSWORD `
    -UseDeviceCode    $USE_DEVICE_CODE

# ============================================
# CHECK ORGANIZATION-LEVEL SMTP AUTH
# ============================================
Write-Host "`nChecking organization-level SMTP AUTH setting ..." -ForegroundColor Cyan

$transportConfig = Get-TransportConfig
$orgDisabled = $transportConfig.SmtpClientAuthenticationDisabled

if ($orgDisabled -eq $true) {
    Write-Host "WARNING: SMTP AUTH is disabled at the organization level." -ForegroundColor Red
    Write-Host "Enabling it now with Set-TransportConfig ..." -ForegroundColor Yellow
    Set-TransportConfig -SmtpClientAuthenticationDisabled $false
    Write-Host "Organization-level SMTP AUTH enabled." -ForegroundColor Green
} else {
    Write-Host "Organization-level SMTP AUTH is already enabled." -ForegroundColor Green
}

# ============================================
# GET ALL USER MAILBOXES
# ============================================
Write-Host "`nFetching all user mailboxes ..." -ForegroundColor Cyan

$mailboxes = Get-CASMailbox -ResultSize Unlimited -Filter "RecipientTypeDetailsValue -eq 'UserMailbox'"
$totalCount = ($mailboxes | Measure-Object).Count

Write-Host "Found $totalCount user mailbox(es)." -ForegroundColor Cyan

if ($totalCount -eq 0) {
    Write-Host "No mailboxes to process." -ForegroundColor Yellow
    Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
    exit 0
}

# ============================================
# ENABLE SMTP AUTH PER MAILBOX
# ============================================
Write-Host "`nProcessing mailboxes ..." -ForegroundColor Yellow

$enabledCount  = 0
$alreadyCount  = 0
$errorCount    = 0
$report = New-Object System.Collections.Generic.List[object]

foreach ($mbx in $mailboxes) {
    $identity = $mbx.PrimarySmtpAddress
    $currentState = $mbx.SmtpClientAuthenticationDisabled

    if ($currentState -eq $false) {
        $alreadyCount++
        $report.Add([pscustomobject]@{
            Mailbox = $identity
            Status  = "AlreadyEnabled"
            Before  = $false
            After   = $false
        })
        continue
    }

    try {
        Set-CASMailbox -Identity $identity -SmtpClientAuthenticationDisabled $false -ErrorAction Stop
        $enabledCount++
        Write-Host "  [ON] $identity" -ForegroundColor Green
        $report.Add([pscustomobject]@{
            Mailbox = $identity
            Status  = "Enabled"
            Before  = $currentState
            After   = $false
        })
    } catch {
        $errorCount++
        Write-Host "  [ERR] $identity : $($_.Exception.Message)" -ForegroundColor Red
        $report.Add([pscustomobject]@{
            Mailbox = $identity
            Status  = "Error"
            Before  = $currentState
            After   = $currentState
        })
    }
}

# ============================================
# SUMMARY
# ============================================
Write-Host "`n" -NoNewline
Write-Host ("=" * 50) -ForegroundColor Magenta
Write-Host "SMTP AUTH SUMMARY" -ForegroundColor Magenta
Write-Host ("=" * 50) -ForegroundColor Magenta
Write-Host "  Total mailboxes    : $totalCount" -ForegroundColor White
Write-Host "  Newly enabled      : $enabledCount" -ForegroundColor Green
Write-Host "  Already enabled    : $alreadyCount" -ForegroundColor Cyan
Write-Host "  Errors             : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Green' })

# ============================================
# CSV EXPORT
# ============================================
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath   = Join-Path $PSScriptRoot "exc-smtpauth-$timestamp.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`nCSV report: $csvPath" -ForegroundColor Green

# ============================================
# DISCONNECT
# ============================================
Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
Write-Host "`nDone." -ForegroundColor Magenta
