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

if ($IsWindows) {
    Set-ExecutionPolicy Unrestricted -Scope Process -Force
}

Install-Module -Name ExchangeOnlineManagement -RequiredVersion 3.0.0

Import-Module ExchangeOnlineManagement

. (Join-Path $PSScriptRoot "_Exc-Connect.ps1")

$anaDomain = $TENANT_DOMAIN
$adminUser = $ADMIN_USER

Connect-ExoSmart `
    -AdminUser        $adminUser `
    -TenantDomain     $anaDomain `
    -AuthMode         $AUTH_MODE `
    -AppId            $APP_ID `
    -CertPfxPath      $CERT_PFX_PATH `
    -CertPfxPassword  $CERT_PFX_PASSWORD `
    -UseDeviceCode    $USE_DEVICE_CODE


foreach($domain in [System.IO.File]::ReadLines($DOMAIN_LIST_FILE))
{
    Write-Output $domain

    New-GlobalAddressList -Name "Default $domain Global Address List" -RecipientFilter {((Alias -ne $null) -and (((ObjectClass -eq 'user') -or (ObjectClass -eq 'contact') -or (ObjectClass -eq 'msExchSystemMailbox') -or (ObjectClass -eq 'msExchDynamicDistributionList') -or (ObjectClass -eq 'group') -or (ObjectClass -eq 'publicFolder'))) -and (WindowsEmailAddress -like "*@$domain") )}

    New-AddressList -Name "All $domain Distribution Lists" -RecipientFilter {((Alias -ne $null) -and (ObjectCategory -like 'group') -and (WindowsEmailAddress -like "*@$domain"))}

    New-AddressList -Name "All $domain Rooms" -RecipientFilter {((Alias -ne $null) -and (((RecipientDisplayType -eq 'ConferenceRoomMailbox') -or (RecipientDisplayType -eq 'SyncedConferenceRoomMailbox'))) -and (WindowsEmailAddress -like "*@$domain"))}

    New-AddressList -Name "All $domain Users" -RecipientFilter {((Alias -ne $null) -and (((((((ObjectCategory -like 'person') -and (ObjectClass -eq 'user') -and (-not(Database -ne $null)) -and (-not(ServerLegacyDN -ne $null)))) -or (((ObjectCategory -like 'person') -and (ObjectClass -eq 'user') -and (((Database -ne $null) -or (ServerLegacyDN -ne $null))))))) -and (-not(RecipientTypeDetailsValue -eq 'GroupMailbox')))) -and (WindowsEmailAddress -like "*@$domain"))}

    New-OfflineAddressBook -Name "$domain Offline Address Book" -AddressLists "Default $domain Global Address List"

    New-AddressBookPolicy -Name "$domain ABP" -AddressLists "All Contacts", "All $domain Distribution Lists", "All $domain Users", "Public Folders" -RoomList "All $domain Rooms" -OfflineAddressBook "$domain Offline Address Book" -GlobalAddressList "Default $domain Global Address List"

    Get-Recipient -Filter '(EmailAddresses -like "*@$domain") -and (recipienttypedetails -eq "usermailbox")' | Set-Mailbox -AddressBookPolicy "$domain ABP"

    Get-Recipient -Filter '(EmailAddresses -like "*@$domain") -and (recipienttypedetails -eq "usermailbox")'

}