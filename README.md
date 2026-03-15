# Exchange Online Multi-Tenant Setup

Exchange Online (Office 365) PowerShell scripts for multi-tenant environment configuration.

## Features

- Domain-specific Address Book Policies (ABP) for tenant isolation
- Catch-all mail routing for unrecognized addresses
- Batch processing for multiple domains
- Secure configuration via .env file

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+ (cross-platform)
- Exchange Online admin credentials
- ExchangeOnlineManagement module v3.0.0

## Installation

### Windows

```powershell
# Install the required module
Install-Module -Name ExchangeOnlineManagement -RequiredVersion 3.0.0

# Verify installation
Get-Module -Name ExchangeOnlineManagement -ListAvailable
```

### macOS

```bash
# Install PowerShell via Homebrew
brew install powershell

# Launch PowerShell
pwsh

# Install the required module (inside pwsh)
Install-Module -Name ExchangeOnlineManagement -RequiredVersion 3.0.0
```

## Configuration

1. Copy `.env.example` to `.env`
2. Edit `.env` with your values:

| Variable           | Description                    | Example                                    |
|--------------------|--------------------------------|--------------------------------------------|
| `TENANT_DOMAIN`    | Primary tenant domain          | `contoso.onmicrosoft.com`                  |
| `ADMIN_USER`       | Admin account UPN              | `admin@contoso.onmicrosoft.com`            |
| `DOMAIN_LIST_FILE` | Path to domain list file       | `C:\domains.txt` or `/path/to/domains.txt` |
| `CATCHALL_PREFIX`  | Catch-all group prefix         | `catchall`                                 |
| `REDIRECT_USER`    | User to receive unmatched mail | `postmaster`                               |

## Domain List File

Create a text file with one domain per line:

```
domain1.com
domain2.com
domain3.com
```

## Usage

### Combined Setup (Recommended)

```powershell
.\Exc-Setup.ps1
```

This script performs both ABP and catch-all configuration for each domain.

### Individual Scripts

```powershell
# Address Book Policy only
.\Exc-Adress.ps1

# Catch-all mail routing only
.\Exc-Yakala.ps1
```

## What Gets Created

For each domain, the script creates:

### Address Book Policy Components

- Global Address List: `Default {domain} Global Address List`
- Address Lists: Distribution Lists, Rooms, Users
- Offline Address Book: `{domain} Offline Address Book`
- Address Book Policy: `{domain} ABP`

### Catch-All Components

- Dynamic Distribution Group: `Yakala DynDistGroup - {domain}`
- Transport Rule: `Yakala TransRule - {domain}`

## Troubleshooting

### Connection Issues

```powershell
# Clear existing sessions
Get-PSSession | Remove-PSSession

# Reconnect manually if needed
Connect-ExchangeOnline -UserPrincipalName admin@tenant.onmicrosoft.com
```

### Verify Configuration

```powershell
# List Address Book Policies
Get-AddressBookPolicy | Format-Table Name, GlobalAddressList

# List Transport Rules
Get-TransportRule | Where-Object {$_.Name -like "Yakala*"}

# Check mailbox ABP assignment
Get-Mailbox user@domain.com | Select-Object AddressBookPolicy
```

## License

Internal use only.
