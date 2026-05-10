# Exchange Online Multi-Tenant Setup — Read-Only Audit Report
# For each domain in DOMAIN_LIST_FILE, report which ABP / catch-all
# resources exist and where catch-all mail is being redirected.
# This script DOES NOT create, modify or delete anything.

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

$adminUser      = $ADMIN_USER
$domainListFile = $DOMAIN_LIST_FILE

if ([string]::IsNullOrWhiteSpace($adminUser)) {
    Write-Host "ERROR: ADMIN_USER is not set in .env" -ForegroundColor Red
    exit 1
}
if ([string]::IsNullOrWhiteSpace($domainListFile) -or -not (Test-Path $domainListFile)) {
    Write-Host "ERROR: DOMAIN_LIST_FILE is missing or path does not exist: $domainListFile" -ForegroundColor Red
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
    -TenantDomain     $TENANT_DOMAIN `
    -AuthMode         $AUTH_MODE `
    -AppId            $APP_ID `
    -CertPfxPath      $CERT_PFX_PATH `
    -CertPfxPassword  $CERT_PFX_PASSWORD `
    -UseDeviceCode    $USE_DEVICE_CODE

# ============================================
# HELPER — silently test if an Exchange object exists
# ============================================
function Test-ExoObject {
    param(
        [Parameter(Mandatory)] [scriptblock] $Get
    )
    try {
        $result = & $Get 2>$null
        if ($null -ne $result) { return $result }
        return $null
    } catch {
        return $null
    }
}

# ============================================
# AUDIT EACH DOMAIN
# ============================================
Write-Host "`nAuditing $((Get-Content $domainListFile).Count) domain(s) ...`n" -ForegroundColor Cyan

$report = foreach ($domain in [System.IO.File]::ReadLines($domainListFile)) {
    $domain = $domain.Trim()
    if ([string]::IsNullOrWhiteSpace($domain)) { continue }

    Write-Host "  -> $domain" -ForegroundColor DarkCyan

    $acceptedDomain = Test-ExoObject { Get-AcceptedDomain -Identity $domain -ErrorAction Stop }
    $gal            = Test-ExoObject { Get-GlobalAddressList   -Identity "Default $domain Global Address List" -ErrorAction Stop }
    $alUsers        = Test-ExoObject { Get-AddressList         -Identity "All $domain Users"               -ErrorAction Stop }
    $alGroups       = Test-ExoObject { Get-AddressList         -Identity "All $domain Distribution Lists"  -ErrorAction Stop }
    $alRooms        = Test-ExoObject { Get-AddressList         -Identity "All $domain Rooms"               -ErrorAction Stop }
    $oab            = Test-ExoObject { Get-OfflineAddressBook  -Identity "$domain Offline Address Book"    -ErrorAction Stop }
    $abp            = Test-ExoObject { Get-AddressBookPolicy   -Identity "$domain ABP"                     -ErrorAction Stop }
    $ddg            = Test-ExoObject { Get-DynamicDistributionGroup -Identity "Yakala DynDistGroup - $domain" -ErrorAction Stop }
    $rule           = Test-ExoObject { Get-TransportRule       -Identity "Yakala TransRule - $domain"      -ErrorAction Stop }

    [pscustomobject]@{
        Domain              = $domain
        DomainType          = if ($acceptedDomain) { $acceptedDomain.DomainType } else { 'NOT-ACCEPTED' }
        HasGAL              = [bool]$gal
        HasUsersAL          = [bool]$alUsers
        HasGroupsAL         = [bool]$alGroups
        HasRoomsAL          = [bool]$alRooms
        HasOAB              = [bool]$oab
        HasABP              = [bool]$abp
        HasCatchAllGroup    = [bool]$ddg
        CatchAllSmtp        = if ($ddg) { $ddg.PrimarySmtpAddress } else { '' }
        HasTransportRule    = [bool]$rule
        RuleState           = if ($rule) { $rule.State } else { '' }
        RedirectsTo         = if ($rule) { ($rule.RedirectMessageTo -join '; ') } else { '' }
        FromScope           = if ($rule) { $rule.FromScope } else { '' }
    }
}

# ============================================
# CONSOLE SUMMARY
# ============================================
Write-Host "`n=========== AUDIT SUMMARY ===========`n" -ForegroundColor Magenta

$report |
    Format-Table Domain, DomainType, HasGAL, HasABP, HasCatchAllGroup, HasTransportRule, RuleState, RedirectsTo `
                 -AutoSize -Wrap

$total                  = ($report | Measure-Object).Count
$fullyConfigured        = ($report | Where-Object {
    $_.HasGAL -and $_.HasUsersAL -and $_.HasGroupsAL -and $_.HasRoomsAL -and
    $_.HasOAB -and $_.HasABP -and $_.HasCatchAllGroup -and $_.HasTransportRule
}).Count
$abpOnly                = ($report | Where-Object { $_.HasABP -and -not $_.HasTransportRule }).Count
$catchAllOnly           = ($report | Where-Object { -not $_.HasABP -and $_.HasTransportRule }).Count
$untouched              = ($report | Where-Object {
    -not $_.HasGAL -and -not $_.HasABP -and -not $_.HasTransportRule
}).Count
$internalRelayCount     = ($report | Where-Object { $_.DomainType -eq 'InternalRelay' }).Count

Write-Host "Total domains          : $total"                  -ForegroundColor White
Write-Host "Fully configured       : $fullyConfigured"        -ForegroundColor Green
Write-Host "ABP only (no catch-all): $abpOnly"                -ForegroundColor Yellow
Write-Host "Catch-all only (no ABP): $catchAllOnly"           -ForegroundColor Yellow
Write-Host "Untouched (none)       : $untouched"              -ForegroundColor Red
Write-Host "InternalRelay domains  : $internalRelayCount"     -ForegroundColor Cyan

# ============================================
# CSV EXPORT
# ============================================
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath   = Join-Path $PSScriptRoot "exc-report-$timestamp.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`nCSV report written to: $csvPath" -ForegroundColor Green

# ============================================
# DISCONNECT
# ============================================
Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
Write-Host "`nDone." -ForegroundColor Magenta
