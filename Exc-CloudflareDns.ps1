# Exchange Online — Cloudflare DNS Sync
# Fetches expected DNS records from Microsoft (MX, SPF, Autodiscover,
# DKIM, DMARC) and creates/updates them in Cloudflare.
#
# Requires:
#   - CF_API_TOKEN in .env (Cloudflare API token with Zone:Read + DNS:Edit)
#   - Exchange Online connection (for Get-DkimSigningConfig)
#
# Modes:
#   DRY_RUN=true  (default) — shows what would change, does not apply
#   DRY_RUN=false — applies changes to Cloudflare

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
$domainListFile = $DOMAIN_LIST_FILE
$cfToken        = $CF_API_TOKEN
$dryRun         = if ($DRY_RUN -and $DRY_RUN.Trim().ToLower() -in @('0','false','no')) { $false } else { $true }

if ([string]::IsNullOrWhiteSpace($tenantDomain)) {
    Write-Host "ERROR: TENANT_DOMAIN is not set in .env" -ForegroundColor Red
    exit 1
}
if ([string]::IsNullOrWhiteSpace($cfToken)) {
    Write-Host "ERROR: CF_API_TOKEN is not set in .env" -ForegroundColor Red
    Write-Host "Create a token at: https://dash.cloudflare.com/profile/api-tokens" -ForegroundColor Yellow
    Write-Host "Required permissions: Zone:Read, DNS:Edit" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $domainListFile)) {
    Write-Host "ERROR: Domain list file not found: $domainListFile" -ForegroundColor Red
    exit 1
}

# ============================================
# MODULE SETUP & CONNECT
# ============================================
if ($IsWindows) {
    Set-ExecutionPolicy Unrestricted -Scope Process -Force
}
Install-Module -Name ExchangeOnlineManagement -RequiredVersion 3.0.0 -Force -AllowClobber
Import-Module ExchangeOnlineManagement

. (Join-Path $PSScriptRoot "_Exc-Connect.ps1")

Connect-ExoSmart `
    -AdminUser        $ADMIN_USER `
    -TenantDomain     $tenantDomain `
    -AuthMode         $AUTH_MODE `
    -AppId            $APP_ID `
    -CertPfxPath      $CERT_PFX_PATH `
    -CertPfxPassword  $CERT_PFX_PASSWORD `
    -UseDeviceCode    $USE_DEVICE_CODE

# ============================================
# FETCH EXPECTED DNS FROM MICROSOFT
# ============================================
Write-Host "`nFetching expected DNS from Microsoft ..." -ForegroundColor Cyan

$msDkimConfigs = @{}
try {
    Get-DkimSigningConfig -ErrorAction Stop | ForEach-Object {
        $msDkimConfigs[$_.Domain] = $_
    }
    Write-Host "  DKIM configs: $($msDkimConfigs.Count) domain(s)" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Could not fetch DKIM configs." -ForegroundColor Yellow
}

$tenantPrefix = ($tenantDomain -replace '\.onmicrosoft\.com$', '')

# ============================================
# CLOUDFLARE API HELPERS
# ============================================
$cfEmail = $CF_EMAIL
if (-not [string]::IsNullOrWhiteSpace($cfEmail)) {
    $cfHeaders = @{
        "X-Auth-Key"   = $cfToken
        "X-Auth-Email" = $cfEmail
        "Content-Type" = "application/json"
    }
} else {
    $cfHeaders = @{
        "Authorization" = "Bearer $cfToken"
        "Content-Type"  = "application/json"
    }
}
$cfBase = "https://api.cloudflare.com/client/v4"

function Invoke-CfApi {
    param(
        [string] $Method,
        [string] $Path,
        [object] $Body
    )
    $uri = "$cfBase$Path"
    $params = @{
        Method  = $Method
        Uri     = $uri
        Headers = $cfHeaders
    }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    try {
        $response = Invoke-RestMethod @params -ErrorAction Stop
        return $response
    } catch {
        Write-Host "    CF API ERROR: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# ============================================
# FETCH ALL CLOUDFLARE ZONES
# ============================================
Write-Host "`nFetching Cloudflare zones ..." -ForegroundColor Cyan

$allZones = @{}
$page = 1
do {
    $response = Invoke-CfApi -Method GET -Path "/zones?per_page=50&page=$page"
    if (-not $response -or -not $response.result) { break }
    foreach ($zone in $response.result) {
        $allZones[$zone.name] = $zone.id
    }
    $totalPages = $response.result_info.total_pages
    $page++
} while ($page -le $totalPages)

Write-Host "  Found $($allZones.Count) zone(s) in Cloudflare." -ForegroundColor Green

# ============================================
# MATCH DOMAINS TO ZONES
# ============================================
$domains = [System.IO.File]::ReadLines($domainListFile) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }

function Find-ZoneForDomain {
    param([string] $Domain)
    $parts = $Domain -split '\.'
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $candidate = ($parts[$i..($parts.Count - 1)]) -join '.'
        if ($allZones.ContainsKey($candidate)) {
            return @{ ZoneName = $candidate; ZoneId = $allZones[$candidate] }
        }
    }
    return $null
}

# ============================================
# DNS RECORD SYNC HELPER
# ============================================
function Sync-DnsRecord {
    param(
        [string] $ZoneId,
        [string] $Type,
        [string] $Name,
        [string] $Content,
        [int]    $Priority = 0,
        [bool]   $Proxied = $false
    )

    $existingResponse = Invoke-CfApi -Method GET -Path "/zones/$ZoneId/dns_records?type=$Type&name=$Name"
    $existing = if ($existingResponse -and $existingResponse.result) { $existingResponse.result } else { @() }

    $recordBody = @{
        type    = $Type
        name    = $Name
        content = $Content
        ttl     = 1
        proxied = $Proxied
    }
    if ($Type -eq 'MX') {
        $recordBody.priority = $Priority
    }

    $action = "SKIP"

    if ($existing.Count -eq 0) {
        $action = "CREATE"
        if (-not $dryRun) {
            $result = Invoke-CfApi -Method POST -Path "/zones/$ZoneId/dns_records" -Body $recordBody
            if ($result -and $result.success) { $action = "CREATED" } else { $action = "CREATE_FAILED" }
        }
    } else {
        $match = $existing | Where-Object { $_.content -eq $Content }
        if (-not $match) {
            $recordId = $existing[0].id
            $action = "UPDATE"
            if (-not $dryRun) {
                $result = Invoke-CfApi -Method PUT -Path "/zones/$ZoneId/dns_records/$recordId" -Body $recordBody
                if ($result -and $result.success) { $action = "UPDATED" } else { $action = "UPDATE_FAILED" }
            }
        } else {
            $action = "OK"
        }
    }

    return $action
}

function Sync-SpfRecord {
    param(
        [string] $ZoneId,
        [string] $Name
    )

    $existingResponse = Invoke-CfApi -Method GET -Path "/zones/$ZoneId/dns_records?type=TXT&name=$Name"
    $existing = if ($existingResponse -and $existingResponse.result) { $existingResponse.result } else { @() }

    $spfRecord = $existing | Where-Object { $_.content -like "v=spf1*" }
    $msInclude = "include:spf.protection.outlook.com"

    if ($spfRecord) {
        if ($spfRecord.content -like "*$msInclude*") {
            return "OK"
        }
        $newContent = $spfRecord.content -replace '~all', "$msInclude ~all" -replace '-all', "$msInclude -all"
        if ($newContent -eq $spfRecord.content) {
            $newContent = $spfRecord.content -replace 'v=spf1', "v=spf1 $msInclude"
        }
        if (-not $dryRun) {
            $body = @{ type = "TXT"; name = $Name; content = $newContent; ttl = 1 }
            $result = Invoke-CfApi -Method PUT -Path "/zones/$ZoneId/dns_records/$($spfRecord.id)" -Body $body
            return if ($result -and $result.success) { "UPDATED" } else { "UPDATE_FAILED" }
        }
        return "UPDATE"
    } else {
        $newContent = "v=spf1 $msInclude ~all"
        if (-not $dryRun) {
            $body = @{ type = "TXT"; name = $Name; content = $newContent; ttl = 1 }
            $result = Invoke-CfApi -Method POST -Path "/zones/$ZoneId/dns_records" -Body $body
            return if ($result -and $result.success) { "CREATED" } else { "CREATE_FAILED" }
        }
        return "CREATE"
    }
}

function Sync-DmarcRecord {
    param(
        [string] $ZoneId,
        [string] $Name
    )

    $existingResponse = Invoke-CfApi -Method GET -Path "/zones/$ZoneId/dns_records?type=TXT&name=$Name"
    $existing = if ($existingResponse -and $existingResponse.result) { $existingResponse.result } else { @() }

    $dmarcRecord = $existing | Where-Object { $_.content -like "v=DMARC1*" }

    if ($dmarcRecord) {
        return "OK"
    }

    $newContent = "v=DMARC1; p=quarantine; rua=mailto:dmarc@$($Name -replace '^_dmarc\.', '')"
    if (-not $dryRun) {
        $body = @{ type = "TXT"; name = $Name; content = $newContent; ttl = 1 }
        $result = Invoke-CfApi -Method POST -Path "/zones/$ZoneId/dns_records" -Body $body
        return if ($result -and $result.success) { "CREATED" } else { "CREATE_FAILED" }
    }
    return "CREATE"
}

# ============================================
# PROCESS EACH DOMAIN
# ============================================
$modeLabel = if ($dryRun) { "DRY RUN (no changes applied)" } else { "LIVE MODE" }
Write-Host "`n$modeLabel" -ForegroundColor $(if ($dryRun) { 'Yellow' } else { 'Red' })
Write-Host ("=" * 80) -ForegroundColor Cyan

$report = New-Object System.Collections.Generic.List[object]

foreach ($domain in $domains) {
    Write-Host "`n  -> $domain" -ForegroundColor Yellow

    $zoneInfo = Find-ZoneForDomain -Domain $domain
    if (-not $zoneInfo) {
        Write-Host "     SKIP: No Cloudflare zone found" -ForegroundColor DarkGray
        $report.Add([pscustomobject]@{
            Domain = $domain; Zone = "N/A"; MX = "NO_ZONE"; SPF = "NO_ZONE"
            Autodiscover = "NO_ZONE"; DKIM1 = "NO_ZONE"; DKIM2 = "NO_ZONE"; DMARC = "NO_ZONE"
        })
        continue
    }

    $zoneId   = $zoneInfo.ZoneId
    $zoneName = $zoneInfo.ZoneName
    Write-Host "     Zone: $zoneName ($zoneId)" -ForegroundColor DarkGray

    $domainDashed = $domain -replace '\.', '-'

    # --- MX ---
    $mxExpected = "$domainDashed.mail.protection.outlook.com"
    $mxAction = Sync-DnsRecord -ZoneId $zoneId -Type MX -Name $domain -Content $mxExpected -Priority 0
    Write-Host "     MX         : $mxAction" -ForegroundColor $(if ($mxAction -eq 'OK') { 'Green' } elseif ($mxAction -like '*FAIL*') { 'Red' } else { 'Cyan' })

    # --- SPF ---
    $spfAction = Sync-SpfRecord -ZoneId $zoneId -Name $domain
    Write-Host "     SPF        : $spfAction" -ForegroundColor $(if ($spfAction -eq 'OK') { 'Green' } elseif ($spfAction -like '*FAIL*') { 'Red' } else { 'Cyan' })

    # --- Autodiscover ---
    $autoAction = Sync-DnsRecord -ZoneId $zoneId -Type CNAME -Name "autodiscover.$domain" -Content "autodiscover.outlook.com"
    Write-Host "     Autodiscovr: $autoAction" -ForegroundColor $(if ($autoAction -eq 'OK') { 'Green' } elseif ($autoAction -like '*FAIL*') { 'Red' } else { 'Cyan' })

    # --- DKIM ---
    $dkimConfig = $msDkimConfigs[$domain]
    if ($dkimConfig) {
        $dkim1Expected = $dkimConfig.Selector1CNAME
        $dkim2Expected = $dkimConfig.Selector2CNAME
    } else {
        $dkim1Expected = "selector1-$domainDashed._domainkey.$tenantPrefix.onmicrosoft.com"
        $dkim2Expected = "selector2-$domainDashed._domainkey.$tenantPrefix.onmicrosoft.com"
    }

    $dkim1Action = Sync-DnsRecord -ZoneId $zoneId -Type CNAME -Name "selector1._domainkey.$domain" -Content $dkim1Expected
    Write-Host "     DKIM sel1  : $dkim1Action" -ForegroundColor $(if ($dkim1Action -eq 'OK') { 'Green' } elseif ($dkim1Action -like '*FAIL*') { 'Red' } else { 'Cyan' })

    $dkim2Action = Sync-DnsRecord -ZoneId $zoneId -Type CNAME -Name "selector2._domainkey.$domain" -Content $dkim2Expected
    Write-Host "     DKIM sel2  : $dkim2Action" -ForegroundColor $(if ($dkim2Action -eq 'OK') { 'Green' } elseif ($dkim2Action -like '*FAIL*') { 'Red' } else { 'Cyan' })

    # --- DMARC ---
    $dmarcAction = Sync-DmarcRecord -ZoneId $zoneId -Name "_dmarc.$domain"
    Write-Host "     DMARC      : $dmarcAction" -ForegroundColor $(if ($dmarcAction -eq 'OK') { 'Green' } elseif ($dmarcAction -like '*FAIL*') { 'Red' } else { 'Cyan' })

    $report.Add([pscustomobject]@{
        Domain       = $domain
        Zone         = $zoneName
        MX           = $mxAction
        SPF          = $spfAction
        Autodiscover = $autoAction
        DKIM1        = $dkim1Action
        DKIM2        = $dkim2Action
        DMARC        = $dmarcAction
    })
}

# ============================================
# SUMMARY
# ============================================
Write-Host "`n" -NoNewline
Write-Host ("=" * 80) -ForegroundColor Magenta
Write-Host "CLOUDFLARE DNS SYNC SUMMARY ($modeLabel)" -ForegroundColor Magenta
Write-Host ("=" * 80) -ForegroundColor Magenta

$total      = $report.Count
$noZone     = ($report | Where-Object { $_.MX -eq 'NO_ZONE' }).Count
$allOk      = ($report | Where-Object { $_.MX -eq 'OK' -and $_.SPF -eq 'OK' -and $_.Autodiscover -eq 'OK' -and $_.DKIM1 -eq 'OK' -and $_.DKIM2 -eq 'OK' -and $_.DMARC -eq 'OK' }).Count
$withChanges = $total - $noZone - $allOk

Write-Host "  Total domains      : $total"
Write-Host "  No Cloudflare zone : $noZone" -ForegroundColor $(if ($noZone -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Already correct    : $allOk" -ForegroundColor Green
Write-Host "  Changes needed     : $withChanges" -ForegroundColor $(if ($withChanges -gt 0) { 'Cyan' } else { 'Green' })

if ($dryRun -and $withChanges -gt 0) {
    Write-Host "`n  To apply changes, set DRY_RUN=false in .env and run again." -ForegroundColor Yellow
}

# ============================================
# CSV EXPORT
# ============================================
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath   = Join-Path $PSScriptRoot "exc-cloudflareDns-$timestamp.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`nCSV report: $csvPath" -ForegroundColor Green

# ============================================
# DISCONNECT
# ============================================
Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
Write-Host "`nDone." -ForegroundColor Magenta
