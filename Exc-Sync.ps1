# Exchange Online — Domain Sync (Cloudflare ↔ Exchange Online)
# Compares Cloudflare zones with Exchange Online accepted domains.
#   - Domains in CF but not in EXO → add to Exchange (with ABP + catch-all)
#   - Domains in EXO but not in CF → flag for removal
#
# Modes:
#   SYNC_MODE=report  (default) — shows differences, no changes
#   SYNC_MODE=apply   — adds missing domains to EXO, sets up ABP + catch-all
#   SYNC_MODE=remove  — removes stale domains from EXO (moves mailboxes to tenant domain first)
#
# Subdomain-aware: host.example.com is NOT stale if example.com exists in CF.

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
$catchAllPrefix = $CATCHALL_PREFIX
$redirectUser   = $REDIRECT_USER
$syncMode       = if ($SYNC_MODE) { $SYNC_MODE.Trim().ToLower() } else { 'report' }
if ($syncMode -notin @('report','apply','remove')) { $syncMode = 'report' }

if ([string]::IsNullOrWhiteSpace($tenantDomain)) {
    Write-Host "ERROR: TENANT_DOMAIN is not set in .env" -ForegroundColor Red; exit 1
}
if ([string]::IsNullOrWhiteSpace($cfToken)) {
    Write-Host "ERROR: CF_API_TOKEN is not set in .env" -ForegroundColor Red; exit 1
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
# CLOUDFLARE API
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
    param([string] $Method, [string] $Path)
    try {
        return Invoke-RestMethod -Method $Method -Uri "$cfBase$Path" -Headers $cfHeaders -ErrorAction Stop
    } catch {
        Write-Host "  CF API ERROR: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# ============================================
# FETCH CLOUDFLARE ZONES
# ============================================
Write-Host "`nFetching Cloudflare zones ..." -ForegroundColor Cyan

$cfZones = @{}
$page = 1
do {
    $response = Invoke-CfApi -Method GET -Path "/zones?per_page=50&page=$page&status=active"
    if (-not $response -or -not $response.result) { break }
    foreach ($zone in $response.result) {
        $cfZones[$zone.name] = $zone.id
    }
    $totalPages = $response.result_info.total_pages
    $page++
} while ($page -le $totalPages)

Write-Host "  Cloudflare zones: $($cfZones.Count)" -ForegroundColor Green

# ============================================
# FETCH EXCHANGE ONLINE ACCEPTED DOMAINS
# ============================================
Write-Host "Fetching Exchange Online accepted domains ..." -ForegroundColor Cyan

$exoDomains = @{}
Get-AcceptedDomain | ForEach-Object {
    $exoDomains[$_.DomainName] = $_.DomainType.ToString()
}

$exoCount = $exoDomains.Count
Write-Host "  Exchange Online domains: $exoCount" -ForegroundColor Green

# ============================================
# COMPARE
# ============================================
Write-Host "`n" -NoNewline
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "DOMAIN COMPARISON" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

# Subdomain check: is a domain (or any parent) a CF zone?
function Test-DomainInCf {
    param([string] $Domain)
    if ($cfZones.ContainsKey($Domain)) { return $true }
    $parts = $Domain -split '\.'
    for ($i = 1; $i -lt $parts.Count - 1; $i++) {
        $parent = ($parts[$i..($parts.Count - 1)]) -join '.'
        if ($cfZones.ContainsKey($parent)) { return $true }
    }
    return $false
}

$inCfNotExo = $cfZones.Keys | Where-Object { -not $exoDomains.ContainsKey($_) } | Sort-Object
$inExoNotCf = $exoDomains.Keys | Where-Object {
    $_ -notlike "*.onmicrosoft.com" -and -not (Test-DomainInCf -Domain $_)
} | Sort-Object
$inBoth = $exoDomains.Keys | Where-Object {
    $_ -notlike "*.onmicrosoft.com" -and (Test-DomainInCf -Domain $_)
} | Sort-Object

Write-Host "`n  In both CF and EXO    : $($inBoth.Count)" -ForegroundColor Green
Write-Host "  In CF, missing in EXO : $($inCfNotExo.Count)" -ForegroundColor $(if ($inCfNotExo.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  In EXO, missing in CF : $($inExoNotCf.Count)" -ForegroundColor $(if ($inExoNotCf.Count -gt 0) { 'Red' } else { 'Green' })

# --- List new domains (CF → EXO) ---
if ($inCfNotExo.Count -gt 0) {
    Write-Host "`n  NEW (will be added to Exchange):" -ForegroundColor Yellow
    foreach ($d in $inCfNotExo) {
        Write-Host "    + $d" -ForegroundColor Yellow
    }
}

# --- List stale domains (EXO → CF) ---
if ($inExoNotCf.Count -gt 0) {
    Write-Host "`n  STALE (in Exchange but no Cloudflare zone — manual review needed):" -ForegroundColor Red
    foreach ($d in $inExoNotCf) {
        $type = $exoDomains[$d]
        Write-Host "    - $d [$type]" -ForegroundColor Red
    }
}

# ============================================
# APPLY: ADD NEW DOMAINS TO EXCHANGE
# ============================================
$addedCount   = 0
$skippedCount = 0
$errorCount   = 0

if ($syncMode -eq 'apply' -and $inCfNotExo.Count -gt 0) {
    Write-Host "`n" -NoNewline
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host "APPLYING: Adding $($inCfNotExo.Count) domain(s) to Exchange Online" -ForegroundColor Magenta
    Write-Host ("=" * 70) -ForegroundColor Magenta

    foreach ($domain in $inCfNotExo) {
        Write-Host "`n  -> $domain" -ForegroundColor Yellow

        # Step 1: Add accepted domain
        try {
            Write-Host "     [1/8] Adding accepted domain ..." -ForegroundColor Yellow
            New-AcceptedDomain -Name $domain -DomainName $domain -DomainType InternalRelay -ErrorAction Stop | Out-Null
            Write-Host "     [1/8] Accepted domain added (InternalRelay)" -ForegroundColor Green
        } catch {
            if ($_.Exception.Message -like "*already exists*") {
                Write-Host "     [1/8] Already exists, skipping ..." -ForegroundColor DarkGray
            } else {
                Write-Host "     [1/8] ERROR: $($_.Exception.Message)" -ForegroundColor Red
                $errorCount++
                continue
            }
        }

        # Step 2: GAL
        try {
            Write-Host "     [2/8] Creating Global Address List ..." -ForegroundColor Yellow
            New-GlobalAddressList -Name "Default $domain Global Address List" `
                -RecipientFilter "((Alias -ne `$null) -and (((ObjectClass -eq 'user') -or (ObjectClass -eq 'contact') -or (ObjectClass -eq 'msExchSystemMailbox') -or (ObjectClass -eq 'msExchDynamicDistributionList') -or (ObjectClass -eq 'group') -or (ObjectClass -eq 'publicFolder'))) -and (WindowsEmailAddress -like '*@$domain'))" `
                -ErrorAction Stop | Out-Null
            Write-Host "     [2/8] GAL created" -ForegroundColor Green
        } catch {
            Write-Host "     [2/8] SKIP: $($_.Exception.Message)" -ForegroundColor DarkGray
        }

        # Step 3: Distribution Lists AL
        try {
            Write-Host "     [3/8] Creating Distribution Lists address list ..." -ForegroundColor Yellow
            New-AddressList -Name "All $domain Distribution Lists" `
                -RecipientFilter "((Alias -ne `$null) -and (ObjectCategory -like 'group') -and (WindowsEmailAddress -like '*@$domain'))" `
                -ErrorAction Stop | Out-Null
            Write-Host "     [3/8] Distribution Lists AL created" -ForegroundColor Green
        } catch {
            Write-Host "     [3/8] SKIP: $($_.Exception.Message)" -ForegroundColor DarkGray
        }

        # Step 4: Rooms AL
        try {
            Write-Host "     [4/8] Creating Rooms address list ..." -ForegroundColor Yellow
            New-AddressList -Name "All $domain Rooms" `
                -RecipientFilter "((Alias -ne `$null) -and (((RecipientDisplayType -eq 'ConferenceRoomMailbox') -or (RecipientDisplayType -eq 'SyncedConferenceRoomMailbox'))) -and (WindowsEmailAddress -like '*@$domain'))" `
                -ErrorAction Stop | Out-Null
            Write-Host "     [4/8] Rooms AL created" -ForegroundColor Green
        } catch {
            Write-Host "     [4/8] SKIP: $($_.Exception.Message)" -ForegroundColor DarkGray
        }

        # Step 5: Users AL
        try {
            Write-Host "     [5/8] Creating Users address list ..." -ForegroundColor Yellow
            New-AddressList -Name "All $domain Users" `
                -RecipientFilter "((Alias -ne `$null) -and (((((((ObjectCategory -like 'person') -and (ObjectClass -eq 'user') -and (-not(Database -ne `$null)) -and (-not(ServerLegacyDN -ne `$null)))) -or (((ObjectCategory -like 'person') -and (ObjectClass -eq 'user') -and (((Database -ne `$null) -or (ServerLegacyDN -ne `$null))))))) -and (-not(RecipientTypeDetailsValue -eq 'GroupMailbox')))) -and (WindowsEmailAddress -like '*@$domain'))" `
                -ErrorAction Stop | Out-Null
            Write-Host "     [5/8] Users AL created" -ForegroundColor Green
        } catch {
            Write-Host "     [5/8] SKIP: $($_.Exception.Message)" -ForegroundColor DarkGray
        }

        # Step 6: OAB
        try {
            Write-Host "     [6/8] Creating Offline Address Book ..." -ForegroundColor Yellow
            New-OfflineAddressBook -Name "$domain Offline Address Book" `
                -AddressLists "Default $domain Global Address List" `
                -ErrorAction Stop | Out-Null
            Write-Host "     [6/8] OAB created" -ForegroundColor Green
        } catch {
            Write-Host "     [6/8] SKIP: $($_.Exception.Message)" -ForegroundColor DarkGray
        }

        # Step 7: ABP
        try {
            Write-Host "     [7/8] Creating Address Book Policy ..." -ForegroundColor Yellow
            New-AddressBookPolicy -Name "$domain ABP" `
                -AddressLists "All Contacts", "All $domain Distribution Lists", "All $domain Users", "Public Folders" `
                -RoomList "All $domain Rooms" `
                -OfflineAddressBook "$domain Offline Address Book" `
                -GlobalAddressList "Default $domain Global Address List" `
                -ErrorAction Stop | Out-Null
            Write-Host "     [7/8] ABP created" -ForegroundColor Green
        } catch {
            Write-Host "     [7/8] SKIP: $($_.Exception.Message)" -ForegroundColor DarkGray
        }

        # Step 8: Catch-all (DDG + Transport Rule)
        try {
            Write-Host "     [8/8] Creating catch-all group and transport rule ..." -ForegroundColor Yellow

            $groupName = "Yakala DynDistGroup - $domain"
            $groupEmail = "$catchAllPrefix@$domain"
            $ruleName  = "Yakala TransRule - $domain"
            $redirectTo = "$redirectUser@$domain"

            New-DynamicDistributionGroup -Name $groupName `
                -PrimarySmtpAddress $groupEmail `
                -RecipientFilter "(RecipientTypeDetails -eq 'UserMailbox') -and (WindowsEmailAddress -eq '*@$domain')" `
                -ErrorAction Stop | Out-Null

            $exceptGroup = if ($CATCHALL_EXCEPT_GROUP) { $CATCHALL_EXCEPT_GROUP } else { $groupEmail }

            New-TransportRule -Name $ruleName `
                -FromScope NotInOrganization `
                -RecipientDomainIs $domain `
                -ExceptIfSentToMemberOf $exceptGroup `
                -RedirectMessageTo $redirectTo `
                -Priority 0 `
                -ErrorAction Stop | Out-Null

            Write-Host "     [8/8] Catch-all configured ($groupEmail -> $redirectTo)" -ForegroundColor Green
        } catch {
            Write-Host "     [8/8] SKIP: $($_.Exception.Message)" -ForegroundColor DarkGray
        }

        $addedCount++
        Write-Host "     DONE" -ForegroundColor Green
    }

    # Update domain list file
    if ($addedCount -gt 0 -and (Test-Path $domainListFile)) {
        Write-Host "`nUpdating domain list file ..." -ForegroundColor Cyan
        $existingDomains = [System.IO.File]::ReadLines($domainListFile) | Where-Object { $_ -and $_.Trim() }
        $allDomains = ($existingDomains + $inCfNotExo) | Sort-Object -Unique
        [System.IO.File]::WriteAllLines($domainListFile, $allDomains)
        Write-Host "  Added $addedCount new domain(s) to $domainListFile" -ForegroundColor Green
    }
}

# ============================================
# REMOVE: CLEAN UP STALE DOMAINS FROM EXCHANGE
# ============================================
$removedCount = 0
$movedMbxCount = 0

if ($syncMode -eq 'remove' -and $inExoNotCf.Count -gt 0) {
    Write-Host "`n" -NoNewline
    Write-Host ("=" * 70) -ForegroundColor Red
    Write-Host "REMOVING: $($inExoNotCf.Count) stale domain(s) from Exchange Online" -ForegroundColor Red
    Write-Host ("=" * 70) -ForegroundColor Red
    Write-Host "  Mailboxes will be moved to $tenantDomain before domain removal." -ForegroundColor Yellow

    foreach ($domain in $inExoNotCf) {
        Write-Host "`n  -> $domain" -ForegroundColor Red

        # Step 1: Move mailboxes to tenant domain
        try {
            $mailboxes = Get-Mailbox -Filter "WindowsEmailAddress -like '*@$domain'" -ResultSize Unlimited -ErrorAction Stop
            if ($mailboxes) {
                $mbxCount = ($mailboxes | Measure-Object).Count
                Write-Host "     [1/7] Moving $mbxCount mailbox(es) to $tenantDomain ..." -ForegroundColor Yellow
                foreach ($mbx in $mailboxes) {
                    $oldUpn = $mbx.UserPrincipalName
                    $alias = ($oldUpn -split '@')[0]
                    $newAddress = "$alias@$tenantDomain"
                    try {
                        Set-Mailbox -Identity $mbx.Identity `
                            -WindowsEmailAddress $newAddress `
                            -AddressBookPolicy $null `
                            -ErrorAction Stop | Out-Null
                        Write-Host "       $oldUpn -> $newAddress" -ForegroundColor Cyan
                        $movedMbxCount++
                    } catch {
                        Write-Host "       ERROR moving $oldUpn : $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            } else {
                Write-Host "     [1/7] No mailboxes on this domain" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "     [1/7] ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }

        # Step 2: Remove Transport Rule
        try {
            Remove-TransportRule -Identity "Yakala TransRule - $domain" -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Host "     [2/7] Transport rule removed" -ForegroundColor Green
        } catch {
            Write-Host "     [2/7] SKIP (not found or error)" -ForegroundColor DarkGray
        }

        # Step 3: Remove Dynamic Distribution Group
        try {
            Remove-DynamicDistributionGroup -Identity "Yakala DynDistGroup - $domain" -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Host "     [3/7] Dynamic distribution group removed" -ForegroundColor Green
        } catch {
            Write-Host "     [3/7] SKIP (not found or error)" -ForegroundColor DarkGray
        }

        # Step 4: Remove ABP
        try {
            Remove-AddressBookPolicy -Identity "$domain ABP" -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Host "     [4/7] Address Book Policy removed" -ForegroundColor Green
        } catch {
            Write-Host "     [4/7] SKIP (not found or error)" -ForegroundColor DarkGray
        }

        # Step 5: Remove OAB
        try {
            Remove-OfflineAddressBook -Identity "$domain Offline Address Book" -Confirm:$false -Force -ErrorAction Stop | Out-Null
            Write-Host "     [5/7] Offline Address Book removed" -ForegroundColor Green
        } catch {
            Write-Host "     [5/7] SKIP (not found or error)" -ForegroundColor DarkGray
        }

        # Step 6: Remove Address Lists + GAL
        $listsToRemove = @(
            "All $domain Distribution Lists",
            "All $domain Rooms",
            "All $domain Users",
            "Default $domain Global Address List"
        )
        $listIdx = 0
        foreach ($listName in $listsToRemove) {
            try {
                if ($listName -like "Default*Global*") {
                    Remove-GlobalAddressList -Identity $listName -Confirm:$false -ErrorAction Stop | Out-Null
                } else {
                    Remove-AddressList -Identity $listName -Confirm:$false -ErrorAction Stop | Out-Null
                }
                $listIdx++
            } catch { }
        }
        Write-Host "     [6/7] Removed $listIdx / $($listsToRemove.Count) address lists" -ForegroundColor $(if ($listIdx -eq $listsToRemove.Count) { 'Green' } else { 'Yellow' })

        # Step 7: Remove Accepted Domain
        try {
            # Reset to Authoritative first if InternalRelay (required before removal)
            Set-AcceptedDomain -Identity $domain -DomainType Authoritative -ErrorAction SilentlyContinue | Out-Null
            Remove-AcceptedDomain -Identity $domain -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Host "     [7/7] Accepted domain removed" -ForegroundColor Green
        } catch {
            Write-Host "     [7/7] ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }

        $removedCount++
        Write-Host "     REMOVED" -ForegroundColor Green
    }
}

# ============================================
# SUMMARY
# ============================================
Write-Host "`n" -NoNewline
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host "SYNC SUMMARY (mode: $syncMode)" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta

Write-Host "  Cloudflare zones     : $($cfZones.Count)"
Write-Host "  Exchange domains     : $exoCount"
Write-Host "  Matched              : $($inBoth.Count)" -ForegroundColor Green
Write-Host "  New (CF -> EXO)      : $($inCfNotExo.Count)" -ForegroundColor Yellow
Write-Host "  Stale (EXO, no CF)   : $($inExoNotCf.Count)" -ForegroundColor $(if ($inExoNotCf.Count -gt 0) { 'Red' } else { 'Green' })

if ($syncMode -eq 'apply') {
    Write-Host "  Added to Exchange    : $addedCount" -ForegroundColor Green
    Write-Host "  Errors               : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Green' })
}

if ($syncMode -eq 'remove') {
    Write-Host "  Removed from Exchange: $removedCount" -ForegroundColor Red
    Write-Host "  Mailboxes moved      : $movedMbxCount" -ForegroundColor Cyan
}

if ($syncMode -eq 'report') {
    if ($inCfNotExo.Count -gt 0) {
        Write-Host "`n  To add new domains, set SYNC_MODE=apply in .env and run again." -ForegroundColor Yellow
    }
    if ($inExoNotCf.Count -gt 0) {
        Write-Host "  To remove stale domains, set SYNC_MODE=remove in .env and run again." -ForegroundColor Red
        Write-Host "  Mailboxes on stale domains will be moved to $tenantDomain first." -ForegroundColor Red
    }
}

# ============================================
# CSV EXPORT
# ============================================
$syncReport = New-Object System.Collections.Generic.List[object]

foreach ($d in $inCfNotExo) {
    $syncReport.Add([pscustomobject]@{ Domain = $d; Status = "NEW_IN_CF"; Action = if ($syncMode -eq 'apply') { "ADDED" } else { "PENDING" } })
}
foreach ($d in $inExoNotCf) {
    $syncReport.Add([pscustomobject]@{ Domain = $d; Status = "STALE_IN_EXO"; Action = "MANUAL_REVIEW" })
}
foreach ($d in $inBoth) {
    $syncReport.Add([pscustomobject]@{ Domain = $d; Status = "IN_SYNC"; Action = "NONE" })
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath   = Join-Path $PSScriptRoot "exc-sync-$timestamp.csv"
$syncReport | Sort-Object Status, Domain | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "`nCSV report: $csvPath" -ForegroundColor Green

# ============================================
# DISCONNECT
# ============================================
Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
Write-Host "`nDone." -ForegroundColor Magenta
