# Exchange Online — Forwarder Forensics (read-only)
# Searches every place where mail can be redirected/forwarded for a list
# of suspect strings.
# Reports the source object, the type of forward, and the matching value.

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

# Suspects: case-insensitive substring matches against every recipient/forward field.
$suspects = @(
    'kaptan',
    'kabahasanoglu',
    'kabahasanoğlu'
)

# ============================================
# MODULE SETUP
# ============================================
if ($IsWindows) {
    Set-ExecutionPolicy Unrestricted -Scope Process -Force
}
Install-Module -Name ExchangeOnlineManagement -RequiredVersion 3.0.0 -Force -AllowClobber
Import-Module ExchangeOnlineManagement

. (Join-Path $PSScriptRoot "_Exc-Connect.ps1")

Connect-ExoSmart `
    -AdminUser        $ADMIN_USER `
    -TenantDomain     $TENANT_DOMAIN `
    -AuthMode         $AUTH_MODE `
    -AppId            $APP_ID `
    -CertPfxPath      $CERT_PFX_PATH `
    -CertPfxPassword  $CERT_PFX_PASSWORD `
    -UseDeviceCode    $USE_DEVICE_CODE

# ============================================
# HELPER — does any suspect substring appear in the given values?
# ============================================
function Test-SuspectMatch {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Values
    )
    if ($null -eq $Values) { return $null }
    $flat = @($Values) | Where-Object { $_ } | ForEach-Object { "$_" }
    foreach ($value in $flat) {
        foreach ($needle in $suspects) {
            if ($value -and $value.ToLowerInvariant().Contains($needle.ToLowerInvariant())) {
                return $value
            }
        }
    }
    return $null
}

$findings = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param(
        [string] $Source,
        [string] $ObjectName,
        [string] $Domain,
        [string] $Field,
        [string] $Value
    )
    $findings.Add([pscustomobject]@{
        Source     = $Source
        ObjectName = $ObjectName
        Domain     = $Domain
        Field      = $Field
        Value      = $Value
    })
}

function Get-DomainFromAddress {
    param([string] $Address)
    if ($Address -match '@(.+)$') { return $matches[1].Trim('>',' ').ToLowerInvariant() }
    return ''
}

# ============================================
# 1) TRANSPORT RULES (every rule, not just Yakala*)
# ============================================
Write-Host "`n[1/5] Scanning transport rules ..." -ForegroundColor Cyan
$rules = Get-TransportRule -ResultSize Unlimited
foreach ($r in $rules) {
    foreach ($field in 'RedirectMessageTo','BlindCopyTo','CopyTo','AddToRecipients',
                       'AddManagerAsRecipientType','ModerateMessageByUser') {
        $val = $r.$field
        if ($null -eq $val) { continue }
        $hit = Test-SuspectMatch -Values $val
        if ($hit) {
            $domain = Get-DomainFromAddress $hit
            Add-Finding -Source 'TransportRule' -ObjectName $r.Name -Domain $domain `
                        -Field $field -Value $hit
        }
    }
}

# ============================================
# 2) MAILBOX-LEVEL FORWARDING
# ============================================
Write-Host "[2/5] Scanning mailbox forwarding settings ..." -ForegroundColor Cyan
$mailboxes = Get-Mailbox -ResultSize Unlimited
foreach ($mb in $mailboxes) {
    foreach ($field in 'ForwardingAddress','ForwardingSmtpAddress') {
        $val = $mb.$field
        if ($null -eq $val) { continue }
        $hit = Test-SuspectMatch -Values $val
        if ($hit) {
            $mbDomain = Get-DomainFromAddress $mb.PrimarySmtpAddress
            Add-Finding -Source 'MailboxForwarding' -ObjectName $mb.PrimarySmtpAddress `
                        -Domain $mbDomain -Field $field -Value $hit
        }
    }
}

# ============================================
# 3) INBOX RULES (per mailbox)
# ============================================
Write-Host "[3/5] Scanning inbox rules ..." -ForegroundColor Cyan
foreach ($mb in $mailboxes) {
    # -IncludeHidden surfaces rules with errors (otherwise Get-InboxRule omits them).
    try {
        $inboxRules = Get-InboxRule -Mailbox $mb.PrimarySmtpAddress -IncludeHidden `
                                    -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        continue
    }
    foreach ($ir in $inboxRules) {
        foreach ($field in 'RedirectTo','ForwardTo','ForwardAsAttachmentTo','SendTextMessageNotificationTo') {
            $val = $ir.$field
            if ($null -eq $val) { continue }
            $hit = Test-SuspectMatch -Values $val
            if ($hit) {
                $mbDomain = Get-DomainFromAddress $mb.PrimarySmtpAddress
                Add-Finding -Source 'InboxRule' `
                            -ObjectName "$($mb.PrimarySmtpAddress) :: $($ir.Name)" `
                            -Domain $mbDomain -Field $field -Value $hit
            }
        }
    }
}

# ============================================
# 4) RECIPIENT ALIASES (kaptan@... or kabahasanoglu@... as a secondary address)
# ============================================
Write-Host "[4/5] Scanning recipient aliases ..." -ForegroundColor Cyan
$recipients = Get-Recipient -ResultSize Unlimited
foreach ($rc in $recipients) {
    if ($null -eq $rc.EmailAddresses) { continue }
    $hit = Test-SuspectMatch -Values $rc.EmailAddresses
    if ($hit) {
        $rcDomain = Get-DomainFromAddress $hit
        Add-Finding -Source 'Alias' -ObjectName "$($rc.PrimarySmtpAddress) ($($rc.RecipientType))" `
                    -Domain $rcDomain -Field 'EmailAddresses' -Value $hit
    }
}

# ============================================
# 5) DISTRIBUTION GROUP MEMBERSHIPS / DDG FILTERS
# ============================================
Write-Host "[5/5] Scanning distribution & dynamic groups ..." -ForegroundColor Cyan
$ddgs = Get-DynamicDistributionGroup -ResultSize Unlimited
foreach ($g in $ddgs) {
    if ($null -eq $g.RecipientFilter) { continue }
    $hit = Test-SuspectMatch -Values $g.RecipientFilter
    if ($hit) {
        $gDomain = Get-DomainFromAddress $g.PrimarySmtpAddress
        Add-Finding -Source 'DynamicDistGroup' -ObjectName $g.Name -Domain $gDomain `
                    -Field 'RecipientFilter' -Value $hit
    }
}
$dgs = Get-DistributionGroup -ResultSize Unlimited
foreach ($g in $dgs) {
    try {
        $members = Get-DistributionGroupMember -Identity $g.Identity -ResultSize Unlimited -ErrorAction Stop
    } catch {
        continue
    }
    foreach ($m in $members) {
        $hit = Test-SuspectMatch @($m.PrimarySmtpAddress, $m.Name, $m.WindowsLiveID)
        if ($hit) {
            $gDomain = Get-DomainFromAddress $g.PrimarySmtpAddress
            Add-Finding -Source 'DistGroupMember' -ObjectName "$($g.Name) :: $($m.PrimarySmtpAddress)" `
                        -Domain $gDomain -Field 'Member' -Value $hit
        }
    }
}

# ============================================
# REPORT
# ============================================
Write-Host "`n=========== FORWARDER FINDINGS ===========`n" -ForegroundColor Magenta

if ($findings.Count -eq 0) {
    Write-Host "No matches found for: $($suspects -join ', ')" -ForegroundColor Yellow
} else {
    $findings |
        Sort-Object Source, Domain, ObjectName |
        Format-Table Source, Domain, ObjectName, Field, Value -AutoSize -Wrap

    $byDomain = $findings | Where-Object { $_.Domain } | Group-Object Domain |
                Sort-Object Count -Descending
    if ($byDomain) {
        Write-Host "`nMatches grouped by domain:" -ForegroundColor Cyan
        $byDomain | Format-Table @{Label='Count';Expression={$_.Count}}, @{Label='Domain';Expression={$_.Name}} -AutoSize
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csvPath   = Join-Path $PSScriptRoot "exc-forwarder-$timestamp.csv"
    $findings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nDetailed CSV: $csvPath" -ForegroundColor Green
}

Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
Write-Host "`nDone." -ForegroundColor Magenta
