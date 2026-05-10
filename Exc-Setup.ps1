# Exchange Online Multi-Tenant Setup Script
# Combines Address Book Policy (ABP) and Catch-All Mail Configuration

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

$anaDomain = $TENANT_DOMAIN
$adminUser = $ADMIN_USER
$domainListFile = $DOMAIN_LIST_FILE
$catchAllPrefix = $CATCHALL_PREFIX
$redirectUser = $REDIRECT_USER

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
    -TenantDomain     $anaDomain `
    -AuthMode         $AUTH_MODE `
    -AppId            $APP_ID `
    -CertPfxPath      $CERT_PFX_PATH `
    -CertPfxPassword  $CERT_PFX_PASSWORD `
    -UseDeviceCode    $USE_DEVICE_CODE

# ============================================
# PROCESS EACH DOMAIN
# ============================================
foreach ($domain in [System.IO.File]::ReadLines($domainListFile)) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Processing domain: $domain" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    # --- ADDRESS BOOK POLICY SETUP ---
    Write-Host "[1/8] Creating Global Address List..." -ForegroundColor Yellow
    New-GlobalAddressList -Name "Default $domain Global Address List" -RecipientFilter {
        ((Alias -ne $null) -and
        (((ObjectClass -eq 'user') -or (ObjectClass -eq 'contact') -or
          (ObjectClass -eq 'msExchSystemMailbox') -or (ObjectClass -eq 'msExchDynamicDistributionList') -or
          (ObjectClass -eq 'group') -or (ObjectClass -eq 'publicFolder'))) -and
        (WindowsEmailAddress -like "*@$domain"))
    }

    Write-Host "[2/8] Creating Distribution Lists Address List..." -ForegroundColor Yellow
    New-AddressList -Name "All $domain Distribution Lists" -RecipientFilter {
        ((Alias -ne $null) -and (ObjectCategory -like 'group') -and (WindowsEmailAddress -like "*@$domain"))
    }

    Write-Host "[3/8] Creating Rooms Address List..." -ForegroundColor Yellow
    New-AddressList -Name "All $domain Rooms" -RecipientFilter {
        ((Alias -ne $null) -and
        (((RecipientDisplayType -eq 'ConferenceRoomMailbox') -or
            (RecipientDisplayType -eq 'SyncedConferenceRoomMailbox'))) -and
        (WindowsEmailAddress -like "*@$domain"))
    }

    Write-Host "[4/8] Creating Users Address List..." -ForegroundColor Yellow
    New-AddressList -Name "All $domain Users" -RecipientFilter {
        ((Alias -ne $null) -and
        (((((((ObjectCategory -like 'person') -and (ObjectClass -eq 'user') -and
                (-not(Database -ne $null)) -and (-not(ServerLegacyDN -ne $null)))) -or
            (((ObjectCategory -like 'person') -and (ObjectClass -eq 'user') -and
                (((Database -ne $null) -or (ServerLegacyDN -ne $null))))))) -and
        (-not(RecipientTypeDetailsValue -eq 'GroupMailbox')))) -and
        (WindowsEmailAddress -like "*@$domain"))
    }

    Write-Host "[5/8] Creating Offline Address Book..." -ForegroundColor Yellow
    New-OfflineAddressBook -Name "$domain Offline Address Book" -AddressLists "Default $domain Global Address List"

    Write-Host "[6/8] Creating Address Book Policy..." -ForegroundColor Yellow
    New-AddressBookPolicy -Name "$domain ABP" `
        -AddressLists "All Contacts", "All $domain Distribution Lists", "All $domain Users", "Public Folders" `
        -RoomList "All $domain Rooms" `
        -OfflineAddressBook "$domain Offline Address Book" `
        -GlobalAddressList "Default $domain Global Address List"

    Write-Host "[7/8] Applying ABP to mailboxes..." -ForegroundColor Yellow
    Get-Recipient -Filter "(EmailAddresses -like '*@$domain') -and (RecipientTypeDetails -eq 'UserMailbox')" |
        Set-Mailbox -AddressBookPolicy "$domain ABP"

    # --- CATCH-ALL MAIL SETUP ---
    $redirectMail = "$redirectUser@$domain"
    $groupName = "$catchAllPrefix@$domain"

    Write-Host "[8/8] Setting up Catch-All mail routing..." -ForegroundColor Yellow

    Set-AcceptedDomain -Identity $domain -DomainType InternalRelay

    New-DynamicDistributionGroup -Name "Yakala DynDistGroup - $domain" `
        -PrimarySmtpAddress $groupName `
        -RecipientFilter "(RecipientTypeDetails -eq 'UserMailbox') -and (WindowsEmailAddress -like '*@$domain')"

    New-TransportRule -Name "Yakala TransRule - $domain" `
        -RecipientDomainIs $domain `
        -FromScope NotInOrganization `
        -ExceptIfSentToMemberOf $groupName `
        -RedirectMessageTo $redirectMail

    Write-Host "`nDomain $domain setup completed!" -ForegroundColor Green
}

# ============================================
# SUMMARY
# ============================================
Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "All domains processed successfully!" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

# Disconnect session (skip if KEEP_SESSION=true)
Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION
