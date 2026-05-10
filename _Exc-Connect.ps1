# Shared Exchange Online connection helper.
# Dot-source this file from other scripts:
#     . (Join-Path $PSScriptRoot "_Exc-Connect.ps1")
#
# Then call:
#     Connect-ExoSmart -AdminUser $adminUser -TenantDomain $tenantDomain `
#                      -AuthMode $AUTH_MODE -AppId $APP_ID `
#                      -CertPfxPath $CERT_PFX_PATH -CertPfxPassword $CERT_PFX_PASSWORD `
#                      -UseDeviceCode $USE_DEVICE_CODE
#     ...
#     Disconnect-ExoIfNeeded -KeepSession $KEEP_SESSION

function Test-ExoActiveSession {
    try {
        $info = Get-ConnectionInformation -ErrorAction Stop
        return [bool]($info | Where-Object {
            $_.State -eq 'Connected' -and $_.TokenStatus -eq 'Active'
        })
    } catch {
        return $false
    }
}

function Connect-ExoSmart {
    [CmdletBinding()]
    param(
        [string] $AdminUser,
        [string] $TenantDomain,
        [string] $AuthMode = 'interactive',
        [string] $AppId,
        [string] $CertPfxPath,
        [string] $CertPfxPassword,
        [string] $UseDeviceCode
    )

    if (Test-ExoActiveSession) {
        Write-Host "Re-using existing Exchange Online session." -ForegroundColor Green
        return
    }

    # Backwards compatibility: USE_DEVICE_CODE=true overrides AuthMode
    if ($UseDeviceCode -and $UseDeviceCode.Trim().ToLower() -in @('1','true','yes')) {
        $AuthMode = 'device'
    }

    $mode = if ($AuthMode) { $AuthMode.Trim().ToLower() } else { 'interactive' }

    switch ($mode) {
        'certificate' {
            if ([string]::IsNullOrWhiteSpace($AppId) -or
                [string]::IsNullOrWhiteSpace($CertPfxPath) -or
                [string]::IsNullOrWhiteSpace($TenantDomain)) {
                throw "AUTH_MODE=certificate requires APP_ID, CERT_PFX_PATH and TENANT_DOMAIN in .env."
            }
            if (-not (Test-Path $CertPfxPath)) {
                throw "Certificate PFX file not found: $CertPfxPath"
            }
            if ([string]::IsNullOrEmpty($CertPfxPassword)) {
                $secure = Read-Host -Prompt "PFX password" -AsSecureString
            } else {
                $secure = ConvertTo-SecureString $CertPfxPassword -AsPlainText -Force
            }

            Write-Host "Connecting via app-only certificate auth ($AppId @ $TenantDomain) ..." -ForegroundColor Cyan
            Connect-ExchangeOnline `
                -AppId $AppId `
                -CertificateFilePath $CertPfxPath `
                -CertificatePassword $secure `
                -Organization $TenantDomain `
                -ShowBanner:$false | Out-Null
        }
        'device' {
            if ([string]::IsNullOrWhiteSpace($AdminUser)) {
                throw "AUTH_MODE=device requires ADMIN_USER in .env."
            }
            Write-Host "Connecting via device-code flow as $AdminUser ..." -ForegroundColor Cyan
            Connect-ExchangeOnline -UserPrincipalName $AdminUser -Device -ShowProgress $true | Out-Null
        }
        default {
            if ([string]::IsNullOrWhiteSpace($AdminUser)) {
                throw "AUTH_MODE=interactive requires ADMIN_USER in .env."
            }
            Write-Host "Connecting via interactive browser auth as $AdminUser ..." -ForegroundColor Cyan
            Connect-ExchangeOnline -UserPrincipalName $AdminUser -ShowProgress $true | Out-Null
        }
    }
}

function Disconnect-ExoIfNeeded {
    [CmdletBinding()]
    param(
        [string] $KeepSession
    )

    if ($KeepSession -and $KeepSession.Trim().ToLower() -in @('1','true','yes')) {
        Write-Host "KEEP_SESSION=true — leaving Exchange Online session active." -ForegroundColor Yellow
        return
    }
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop | Out-Null
    } catch {
        # Already disconnected or no active session
    }
}
