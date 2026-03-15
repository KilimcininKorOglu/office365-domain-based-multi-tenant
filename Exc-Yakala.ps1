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

$anaDomain = $TENANT_DOMAIN
$adminUser = $ADMIN_USER

Connect-ExchangeOnline -UserPrincipalName $adminUser -ShowProgress $true


foreach($domain in [System.IO.File]::ReadLines($DOMAIN_LIST_FILE))
{
    Write-Output $domain

    $redirectMail = "$REDIRECT_USER@$domain"

    $groupName = "$CATCHALL_PREFIX@$domain"

    Set-AcceptedDomain -Identity $domain -DomainType InternalRelay

    New-DynamicDistributionGroup -Name "Yakala DynDistGroup - $domain"-PrimarySmtpAddress $GroupName -RecipientFilter "(RecipientTypeDetails -eq 'UserMailbox') -and (WindowsEmailAddress -eq '*@$domain')"

    Get-Recipient -RecipientPreviewFilter (Get-DynamicDistributionGroup "Yakala DynDistGroup - $domain").RecipientFilter

    New-TransportRule -Name "Yakala TransRule - $domain" -RecipientDomainIs $domain -FromScope NotInOrganization -ExceptIfSentToMemberOf $GroupName -RedirectMessageTo $redirectmail

 }