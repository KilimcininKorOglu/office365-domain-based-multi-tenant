# Exchange Online — DNS Record Validation (read-only)
# Connects to Exchange Online to fetch Microsoft's expected DNS records
# (MX via Get-AcceptedDomain, DKIM via Get-DkimSigningConfig), then
# compares them against actual DNS using dig (macOS/Linux) or
# Resolve-DnsName (Windows).
#
# Checks: MX, SPF, Autodiscover CNAME, DKIM CNAME x2, DMARC TXT

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

if ([string]::IsNullOrWhiteSpace($tenantDomain)) {
    Write-Host "ERROR: TENANT_DOMAIN is not set in .env" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $domainListFile)) {
    Write-Host "ERROR: Domain list file not found: $domainListFile" -ForegroundColor Red
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
Write-Host "`nFetching expected DNS records from Microsoft ..." -ForegroundColor Cyan

$msAcceptedDomains = @{}
Get-AcceptedDomain | ForEach-Object {
    $msAcceptedDomains[$_.DomainName] = $_
}

$msDkimConfigs = @{}
try {
    Get-DkimSigningConfig -ErrorAction Stop | ForEach-Object {
        $msDkimConfigs[$_.Domain] = $_
    }
} catch {
    Write-Host "WARNING: Could not fetch DKIM configs (Get-DkimSigningConfig). Using calculated patterns." -ForegroundColor Yellow
}

$tenantPrefix = ($tenantDomain -replace '\.onmicrosoft\.com$', '')

# ============================================
# DNS QUERY HELPER (cross-platform)
# ============================================
function Invoke-DnsQuery {
    param(
        [string] $Name,
        [string] $Type
    )
    try {
        if ($IsWindows) {
            $results = Resolve-DnsName -Name $Name -Type $Type -ErrorAction Stop 2>$null
            switch ($Type) {
                'MX'    { return ($results | Where-Object { $_.QueryType -eq 'MX' } | ForEach-Object { $_.NameExchange }) }
                'TXT'   { return ($results | Where-Object { $_.QueryType -eq 'TXT' } | ForEach-Object { $_.Strings -join '' }) }
                'CNAME' { return ($results | Where-Object { $_.QueryType -eq 'CNAME' } | ForEach-Object { $_.NameHost }) }
            }
        } else {
            $output = dig +short $Name $Type 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) { return @() }
            $lines = $output -split "`n" | Where-Object { $_ -and $_.Trim() }
            switch ($Type) {
                'MX'    { return ($lines | ForEach-Object { ($_ -replace '^\d+\s+', '').TrimEnd('.') }) }
                'TXT'   { return ($lines | ForEach-Object { $_ -replace '"', '' }) }
                'CNAME' { return ($lines | ForEach-Object { $_.TrimEnd('.') }) }
            }
        }
    } catch {
        return @()
    }
}

# ============================================
# BUILD EXPECTED VALUES PER DOMAIN
# ============================================
function Get-ExpectedDns {
    param([string] $Domain)

    $domainDashed = $Domain -replace '\.', '-'

    $expectedMx = "$domainDashed.mail.protection.outlook.com"

    # DKIM: use Microsoft's actual config if available, otherwise calculate
    $dkimConfig = $msDkimConfigs[$Domain]
    if ($dkimConfig) {
        $dkim1Host   = $dkimConfig.Selector1CNAME
        $dkim2Host   = $dkimConfig.Selector2CNAME
        $dkimEnabled = $dkimConfig.Enabled
    } else {
        $dkim1Host   = "selector1-$domainDashed._domainkey.$tenantPrefix.onmicrosoft.com"
        $dkim2Host   = "selector2-$domainDashed._domainkey.$tenantPrefix.onmicrosoft.com"
        $dkimEnabled = $null
    }

    # Domain type from Microsoft
    $acceptedDomain = $msAcceptedDomains[$Domain]
    $domainType     = if ($acceptedDomain) { $acceptedDomain.DomainType.ToString() } else { "NotFound" }

    return @{
        MX           = $expectedMx
        SPF          = "include:spf.protection.outlook.com"
        Autodiscover = "autodiscover.outlook.com"
        DKIM1        = $dkim1Host
        DKIM2        = $dkim2Host
        DKIMEnabled  = $dkimEnabled
        DomainType   = $domainType
        DKIMSource   = if ($dkimConfig) { "Microsoft" } else { "Calculated" }
    }
}

# ============================================
# CHECK EACH DOMAIN
# ============================================
$domains = [System.IO.File]::ReadLines($domainListFile) | Where-Object { $_ -and $_.Trim() }
$domainCount = ($domains | Measure-Object).Count

Write-Host "`nDNS validation for $domainCount domain(s)" -ForegroundColor Cyan
Write-Host "Tenant: $tenantDomain" -ForegroundColor Cyan
Write-Host "DKIM configs from Microsoft: $($msDkimConfigs.Count) domain(s)" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan

$report = New-Object System.Collections.Generic.List[object]

foreach ($domain in $domains) {
    $domain = $domain.Trim()
    if ([string]::IsNullOrWhiteSpace($domain)) { continue }

    Write-Host "`n  -> $domain" -ForegroundColor Yellow
    $expected = Get-ExpectedDns -Domain $domain

    $dkimLabel = if ($expected.DKIMEnabled -eq $true) { "DKIM ON" }
                 elseif ($expected.DKIMEnabled -eq $false) { "DKIM OFF" }
                 else { "DKIM N/A" }
    Write-Host "     [$($expected.DomainType)] [$dkimLabel] [DKIM source: $($expected.DKIMSource)]" -ForegroundColor DarkGray

    # --- MX ---
    $mxRecords = @(Invoke-DnsQuery -Name $domain -Type MX)
    $mxMatch   = $mxRecords | Where-Object { $_ -like "*mail.protection.outlook.com" }
    $mxStatus  = if ($mxMatch) { "OK" } else { "MISSING" }
    $mxActual  = if ($mxRecords) { $mxRecords -join '; ' } else { "(none)" }
    Write-Host "     MX         : $mxStatus  [$mxActual]" -ForegroundColor $(if ($mxMatch) { 'Green' } else { 'Red' })

    # --- SPF ---
    $txtRecords = @(Invoke-DnsQuery -Name $domain -Type TXT)
    $spfRecord  = $txtRecords | Where-Object { $_ -like "v=spf1*" }
    $spfHasMs   = $spfRecord | Where-Object { $_ -like "*spf.protection.outlook.com*" }
    $spfStatus  = if ($spfHasMs) { "OK" } elseif ($spfRecord) { "NO_MICROSOFT" } else { "MISSING" }
    $spfActual  = if ($spfRecord) { $spfRecord -join '; ' } else { "(none)" }
    Write-Host "     SPF        : $spfStatus" -ForegroundColor $(if ($spfHasMs) { 'Green' } elseif ($spfRecord) { 'Yellow' } else { 'Red' })

    # --- Autodiscover ---
    $autoRecords = @(Invoke-DnsQuery -Name "autodiscover.$domain" -Type CNAME)
    $autoMatch   = $autoRecords | Where-Object { $_ -like "*autodiscover.outlook.com*" }
    $autoStatus  = if ($autoMatch) { "OK" } else { "MISSING" }
    $autoActual  = if ($autoRecords) { $autoRecords -join '; ' } else { "(none)" }
    Write-Host "     Autodiscovr: $autoStatus" -ForegroundColor $(if ($autoMatch) { 'Green' } else { 'Red' })

    # --- DKIM selector1 ---
    $dkim1Records = @(Invoke-DnsQuery -Name "selector1._domainkey.$domain" -Type CNAME)
    $dkim1Match   = $dkim1Records | Where-Object { $_ -like "*._domainkey.*onmicrosoft.com*" }
    $dkim1Status  = if ($dkim1Match) { "OK" } else { "MISSING" }
    $dkim1Actual  = if ($dkim1Records) { $dkim1Records -join '; ' } else { "(none)" }
    Write-Host "     DKIM sel1  : $dkim1Status  [expected: $($expected.DKIM1)]" -ForegroundColor $(if ($dkim1Match) { 'Green' } else { 'Red' })

    # --- DKIM selector2 ---
    $dkim2Records = @(Invoke-DnsQuery -Name "selector2._domainkey.$domain" -Type CNAME)
    $dkim2Match   = $dkim2Records | Where-Object { $_ -like "*._domainkey.*onmicrosoft.com*" }
    $dkim2Status  = if ($dkim2Match) { "OK" } else { "MISSING" }
    $dkim2Actual  = if ($dkim2Records) { $dkim2Records -join '; ' } else { "(none)" }
    Write-Host "     DKIM sel2  : $dkim2Status  [expected: $($expected.DKIM2)]" -ForegroundColor $(if ($dkim2Match) { 'Green' } else { 'Red' })

    # --- DMARC ---
    $dmarcRecords = @(Invoke-DnsQuery -Name "_dmarc.$domain" -Type TXT)
    $dmarcRecord  = $dmarcRecords | Where-Object { $_ -like "v=DMARC1*" }
    $dmarcStatus  = if ($dmarcRecord) { "OK" } else { "MISSING" }
    $dmarcActual  = if ($dmarcRecord) { $dmarcRecord -join '; ' } else { "(none)" }
    Write-Host "     DMARC      : $dmarcStatus" -ForegroundColor $(if ($dmarcRecord) { 'Green' } else { 'Red' })

    # --- Collect ---
    $report.Add([pscustomobject]@{
        Domain             = $domain
        DomainType         = $expected.DomainType
        DKIM_Enabled       = $expected.DKIMEnabled
        DKIM_Source        = $expected.DKIMSource
        MX_Status          = $mxStatus
        MX_Actual          = $mxActual
        MX_Expected        = $expected.MX
        SPF_Status         = $spfStatus
        SPF_Actual         = $spfActual
        Autodiscovr_Status = $autoStatus
        Autodiscovr_Actual = $autoActual
        DKIM1_Status       = $dkim1Status
        DKIM1_Actual       = $dkim1Actual
        DKIM1_Expected     = $expected.DKIM1
        DKIM2_Status       = $dkim2Status
        DKIM2_Actual       = $dkim2Actual
        DKIM2_Expected     = $expected.DKIM2
        DMARC_Status       = $dmarcStatus
        DMARC_Actual       = $dmarcActual
    })
}

# ============================================
# SUMMARY
# ============================================
Write-Host "`n" -NoNewline
Write-Host ("=" * 80) -ForegroundColor Magenta
Write-Host "DNS VALIDATION SUMMARY" -ForegroundColor Magenta
Write-Host ("=" * 80) -ForegroundColor Magenta

$mxOk    = ($report | Where-Object { $_.MX_Status -eq 'OK' }).Count
$spfOk   = ($report | Where-Object { $_.SPF_Status -eq 'OK' }).Count
$autoOk  = ($report | Where-Object { $_.Autodiscovr_Status -eq 'OK' }).Count
$dkim1Ok = ($report | Where-Object { $_.DKIM1_Status -eq 'OK' }).Count
$dkim2Ok = ($report | Where-Object { $_.DKIM2_Status -eq 'OK' }).Count
$dmarcOk = ($report | Where-Object { $_.DMARC_Status -eq 'OK' }).Count
$total   = $report.Count

Write-Host "  MX records         : $mxOk / $total OK" -ForegroundColor $(if ($mxOk -eq $total) { 'Green' } else { 'Yellow' })
Write-Host "  SPF records        : $spfOk / $total OK" -ForegroundColor $(if ($spfOk -eq $total) { 'Green' } else { 'Yellow' })
Write-Host "  Autodiscover CNAME : $autoOk / $total OK" -ForegroundColor $(if ($autoOk -eq $total) { 'Green' } else { 'Yellow' })
Write-Host "  DKIM selector1     : $dkim1Ok / $total OK" -ForegroundColor $(if ($dkim1Ok -eq $total) { 'Green' } else { 'Yellow' })
Write-Host "  DKIM selector2     : $dkim2Ok / $total OK" -ForegroundColor $(if ($dkim2Ok -eq $total) { 'Green' } else { 'Yellow' })
Write-Host "  DMARC policy       : $dmarcOk / $total OK" -ForegroundColor $(if ($dmarcOk -eq $total) { 'Green' } else { 'Yellow' })

$fullyOk = ($report | Where-Object {
    $_.MX_Status -eq 'OK' -and $_.SPF_Status -eq 'OK' -and
    $_.Autodiscovr_Status -eq 'OK' -and $_.DKIM1_Status -eq 'OK' -and
    $_.DKIM2_Status -eq 'OK' -and $_.DMARC_Status -eq 'OK'
}).Count

Write-Host "`n  Fully configured   : $fullyOk / $total" -ForegroundColor $(if ($fullyOk -eq $total) { 'Green' } else { 'Red' })

# ============================================
# CSV EXPORT
# ============================================
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath   = Join-Path $PSScriptRoot "exc-dnscheck-$timestamp.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`nCSV report: $csvPath" -ForegroundColor Green

# ============================================
# DISCONNECT
# ============================================
Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
Write-Host "`nDone." -ForegroundColor Magenta
