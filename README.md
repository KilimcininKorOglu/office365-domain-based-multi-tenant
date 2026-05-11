# Exchange Online Multi-Tenant Setup

Exchange Online (Office 365) PowerShell scripts for domain-based multi-tenant environment configuration. Each accepted domain in a single tenant is isolated with its own Address Book Policy (ABP) and given catch-all mail routing for unrecognized recipients.

## Features

- Domain-specific Address Book Policies (ABP) for tenant isolation
- Catch-all mail routing for unrecognized addresses via `InternalRelay` accepted domain plus a transport rule
- Three authentication modes: interactive (browser MFA), device code, and certificate-based (unattended)
- Automatic domain list fetching from the tenant
- Read-only audit reporting with CSV export
- Forwarder forensics scanning across transport rules, mailbox forwarding, inbox rules, aliases, and distribution groups
- DNS record validation against Microsoft expected values (MX, SPF, Autodiscover, DKIM, DMARC)
- Bulk authenticated SMTP enablement for all tenant mailboxes
- Cloudflare DNS sync with dry-run safety mode
- Bidirectional domain sync between Cloudflare and Exchange Online (add new, flag stale)
- Batch processing across all domains listed in a single text file
- Secure configuration via `.env` (no credentials in source)
- Cross-platform: PowerShell 7+ (macOS, Linux) and Windows PowerShell 5.1

## Repository Layout

### Scripts

**`_Exc-Connect.ps1`** -- Shared connection helper, dot-sourced by every operational script. Provides `Connect-ExoSmart` (selects interactive, device-code, or certificate auth based on `AUTH_MODE`), `Test-ExoActiveSession` (reuses existing sessions), and `Disconnect-ExoIfNeeded` (skips disconnect when `KEEP_SESSION=true`). Never run directly.

**`Exc-Setup.ps1`** -- Primary production script. Runs an 8-step pipeline per domain: creates GAL, three address lists, OAB, ABP, assigns ABP to all domain mailboxes, then configures catch-all (sets `InternalRelay`, creates dynamic distribution group, creates transport rule). Colored progress output. Disconnects at the end.

**`Exc-Address.ps1`** -- ABP-only standalone script. Creates GAL, address lists, OAB, ABP, and assigns ABP to mailboxes for each domain. Does not configure catch-all. Historical reference; prefer `Exc-Setup.ps1`.

**`Exc-CatchAll.ps1`** -- Catch-all-only standalone script. Sets each domain to `InternalRelay`, creates a dynamic distribution group (`Yakala DynDistGroup`), and creates a transport rule (`Yakala TransRule`) that redirects unmatched external mail to `REDIRECT_USER`. Historical reference; prefer `Exc-Setup.ps1`.

**`Exc-Domains.ps1`** -- Connects to Exchange Online, runs `Get-AcceptedDomain`, excludes the primary tenant domain, sorts and deduplicates, backs up the existing file as `.bak`, and writes the result to `DOMAIN_LIST_FILE`. Run this before `Exc-Setup.ps1` to auto-populate the domain list.

**`Exc-Report.ps1`** -- Read-only audit script. For each domain in `DOMAIN_LIST_FILE`, probes whether GAL, address lists, OAB, ABP, dynamic distribution group, and transport rule exist. Prints a formatted console summary with counters (fully configured / ABP-only / catch-all-only / untouched) and exports a timestamped CSV (`exc-report-YYYYMMDD-HHMMSS.csv`). Creates and modifies nothing.

**`Exc-FindForwarder.ps1`** -- Read-only forwarder forensics scanner. Searches five surfaces (transport rules, mailbox `ForwardingAddress`/`ForwardingSmtpAddress`, inbox rules including hidden ones, recipient email aliases, and distribution group memberships) for case-insensitive substring matches against a hardcoded suspects list. Outputs a grouped console table and a timestamped CSV (`exc-forwarder-YYYYMMDD-HHMMSS.csv`).

**`Exc-DnsCheck.ps1`** -- DNS record validation. Connects to Exchange Online to fetch real expected values (`Get-DkimSigningConfig` for DKIM CNAME targets, `Get-AcceptedDomain` for domain types), then queries actual DNS via `dig` (macOS/Linux) or `Resolve-DnsName` (Windows). Checks MX, SPF, Autodiscover CNAME, DKIM selector1/selector2 CNAMEs, and DMARC TXT for each domain. Outputs a timestamped CSV (`exc-dnscheck-YYYYMMDD-HHMMSS.csv`). Read-only.

**`Exc-SmtpAuth.ps1`** -- Enables authenticated SMTP (port 587) for all user mailboxes. Checks and enables the organization-level setting (`Set-TransportConfig -SmtpClientAuthenticationDisabled $false`), then iterates every `UserMailbox` and sets `Set-CASMailbox -SmtpClientAuthenticationDisabled $false`. Skips mailboxes already enabled. Outputs a timestamped CSV (`exc-smtpauth-YYYYMMDD-HHMMSS.csv`).

**`Exc-CloudflareDns.ps1`** -- Syncs Microsoft 365 DNS records to Cloudflare. Connects to Exchange Online for DKIM config, then uses the Cloudflare API to create or update MX, SPF (TXT), Autodiscover (CNAME), DKIM (CNAME x2), and DMARC (TXT) records for each domain. Supports both Global API Key (`X-Auth-Key` + `X-Auth-Email`) and API Token (`Bearer`) auth. `DRY_RUN=true` (default) previews changes without applying.

**`Exc-Sync.ps1`** -- Bidirectional domain sync between Cloudflare and Exchange Online. Compares Cloudflare zones with Exchange accepted domains. Subdomain-aware: `host.example.com` is not flagged as stale if `example.com` exists in Cloudflare. Three modes:
- `SYNC_MODE=report` (default) -- shows differences only.
- `SYNC_MODE=apply` -- adds new domains to Exchange with full 8-step ABP + catch-all setup, updates `domains.txt`.
- `SYNC_MODE=remove` -- moves mailboxes on stale domains to the tenant domain (`Set-Mailbox -WindowsEmailAddress`), removes ABP, address lists, OAB, transport rules, dynamic distribution groups, and the accepted domain. Outputs a timestamped CSV (`exc-sync-YYYYMMDD-HHMMSS.csv`).

**`Exc-CertSetup.ps1`** -- One-time certificate bootstrap. Generates a 2048-bit RSA self-signed certificate (2-year validity) using cross-platform .NET `CertificateRequest` APIs. Exports PFX (private key) and CER (public key) to `certs/`. Prompts for a PFX password with confirmation. Sets `chmod 600` on POSIX. Prints the Azure AD setup steps. Does not contact Exchange Online.

### Other Files

| File           | Purpose                                                    |
|----------------|------------------------------------------------------------|
| `.env.example` | Configuration template; copy to `.env` and fill in values. |
| `.env`         | Runtime configuration with credentials (gitignored).       |
| `domains.txt`  | Domain list file, one domain per line (gitignored).        |
| `certs/`       | PFX and CER certificate storage directory (gitignored).    |

## Prerequisites

- PowerShell 7+ (cross-platform) or Windows PowerShell 5.1
- Exchange Online administrator credentials (interactive/device mode) or an Azure AD App Registration with `Exchange.ManageAsApp` permission (certificate mode)
- `ExchangeOnlineManagement` module v3.0.0
- Cloudflare API Key or Token (only for `Exc-CloudflareDns.ps1` and `Exc-Sync.ps1`)

## Installation

### Windows

```powershell
Install-Module -Name ExchangeOnlineManagement -RequiredVersion 3.0.0
Get-Module -Name ExchangeOnlineManagement -ListAvailable
```

### macOS / Linux

```bash
brew install powershell
pwsh -Command "Install-Module -Name ExchangeOnlineManagement -RequiredVersion 3.0.0"
```

## Configuration

1. Copy `.env.example` to `.env`.
2. Edit `.env` with your values.

### Core Variables

| Variable           | Description                    | Example                                    |
|--------------------|--------------------------------|--------------------------------------------|
| `TENANT_DOMAIN`    | Primary tenant domain          | `contoso.onmicrosoft.com`                  |
| `ADMIN_USER`       | Admin account UPN              | `admin@contoso.onmicrosoft.com`            |
| `DOMAIN_LIST_FILE` | Path to domain list file       | `C:\domains.txt` or `/path/to/domains.txt` |
| `CATCHALL_PREFIX`  | Catch-all group prefix         | `catchall`                                 |
| `REDIRECT_USER`    | User to receive unmatched mail | `postmaster`                               |

### Authentication Variables

| Variable            | Description                                                  | Default       |
|---------------------|--------------------------------------------------------------|---------------|
| `AUTH_MODE`         | Connection method: `interactive`, `device`, or `certificate` | `interactive` |
| `APP_ID`            | Azure AD App Registration client ID (certificate mode only)  |               |
| `CERT_PFX_PATH`     | Path to PFX file generated by `Exc-CertSetup.ps1`            |               |
| `CERT_PFX_PASSWORD` | Password protecting the PFX file                             |               |
| `KEEP_SESSION`      | Keep Exchange session open after script finishes             | `false`       |
| `USE_DEVICE_CODE`   | Legacy flag; overrides `AUTH_MODE` when set to `true`        | `false`       |

### Cloudflare Variables

| Variable       | Description                                                      | Default  |
|----------------|------------------------------------------------------------------|----------|
| `CF_API_TOKEN` | Cloudflare Global API Key or API Token                           |          |
| `CF_EMAIL`     | Cloudflare account email (required for Global API Key auth only) |          |
| `DRY_RUN`      | Cloudflare DNS sync mode (`true` = preview, `false` = apply)     | `true`   |
| `SYNC_MODE`    | Domain sync mode: `report`, `apply`, or `remove`                 | `report` |

`.env` is parsed by the regex `^\s*([^#][^=]+)=(.*)$` and injected as script-scoped variables. Lines starting with `#` are ignored.

## Domain List File

Create a UTF-8 text file referenced by `DOMAIN_LIST_FILE`, with one accepted domain per line:

```
domain1.com
domain2.com
domain3.com
```

Alternatively, run `Exc-Domains.ps1` to auto-populate the file from the tenant's accepted domains.

## Usage

### Combined Setup (Recommended)

```powershell
.\Exc-Setup.ps1
```

Runs the full eight-step pipeline per domain (ABP + catch-all) and disconnects the Exchange Online session at the end.

### Individual Scripts

```powershell
# Address Book Policy only
.\Exc-Address.ps1

# Catch-all mail routing only
.\Exc-CatchAll.ps1
```

### Utility Scripts

```powershell
# Auto-populate domain list from tenant
.\Exc-Domains.ps1

# Read-only audit report (outputs CSV)
.\Exc-Report.ps1

# Forwarder forensics scan (outputs CSV)
.\Exc-FindForwarder.ps1

# DNS record validation against Microsoft expected values (outputs CSV)
.\Exc-DnsCheck.ps1

# Enable authenticated SMTP for all mailboxes (outputs CSV)
.\Exc-SmtpAuth.ps1
```

### Cloudflare Integration

```powershell
# Preview DNS changes (dry run, no modifications)
.\Exc-CloudflareDns.ps1

# Apply DNS changes to Cloudflare (set DRY_RUN=false in .env first)
.\Exc-CloudflareDns.ps1

# Compare Cloudflare zones with Exchange domains (report mode)
.\Exc-Sync.ps1

# Add new Cloudflare domains to Exchange (set SYNC_MODE=apply in .env)
.\Exc-Sync.ps1

# Remove stale domains from Exchange (set SYNC_MODE=remove in .env)
# Moves mailboxes to tenant domain before cleanup
.\Exc-Sync.ps1
```

## Certificate-Based Authentication Setup

For unattended operation without browser prompts or MFA.

### Step 1 -- Generate Certificate

```powershell
.\Exc-CertSetup.ps1
```

You will be prompted for a PFX password (enter twice). The script generates two files under `certs/`:

| File                   | Content                      |
|------------------------|------------------------------|
| `exo-app-{tenant}.pfx` | Private key (keep secret)    |
| `exo-app-{tenant}.cer` | Public key (upload to Azure) |

### Step 2 -- Create Azure AD App Registration

1. Open [Microsoft Entra admin center](https://entra.microsoft.com).
2. Navigate to **Entra ID** > **App registrations** > **New registration**.
3. Set a name (e.g. `ExchangeOnline-Automation`).
4. Supported account types: **Accounts in this organizational directory only** (single tenant).
5. Leave Redirect URI empty. Click **Register**.
6. Copy the **Application (client) ID** -- this is your `APP_ID`.

### Step 3 -- Upload Certificate

1. In the app registration, go to **Certificates & secrets**.
2. Select the **Certificates** tab.
3. Click **Upload certificate** and select the `.cer` file from `certs/`.

### Step 4 -- Add API Permission

1. Go to **API permissions** > **Add a permission**.
2. Select the **APIs my organization uses** tab.
3. Search for and select **Office 365 Exchange Online**.
4. Select **Application permissions**.
5. Expand **Exchange** and check **Exchange.ManageAsApp**.
6. Click **Add permissions**.
7. Click **Grant admin consent for {your tenant}** and confirm with **Yes**.

### Step 5 -- Assign Exchange Administrator Role

1. In the Entra admin center, go to **Entra ID** > **Roles & admins**.
2. Search for and click **Exchange Administrator**.
3. Click **Add assignments**.
4. Search for your app name (e.g. `ExchangeOnline-Automation`).
5. Select the entry with your `APP_ID` and click **Add**.

### Step 6 -- Configure .env

```ini
AUTH_MODE=certificate
APP_ID=<Application (client) ID from Step 2>
CERT_PFX_PATH=./certs/exo-app-{tenant}.pfx
CERT_PFX_PASSWORD=<the password you chose in Step 1>
```

### Verify

```powershell
.\Exc-Report.ps1
```

The script should connect without opening a browser or prompting for MFA.

## What Gets Created Per Domain

### Address Book Policy Components

| Resource              | Naming Pattern                         |
|-----------------------|----------------------------------------|
| Global Address List   | `Default {domain} Global Address List` |
| Distribution Lists AL | `All {domain} Distribution Lists`      |
| Rooms Address List    | `All {domain} Rooms`                   |
| Users Address List    | `All {domain} Users`                   |
| Offline Address Book  | `{domain} Offline Address Book`        |
| Address Book Policy   | `{domain} ABP`                         |
| Mailbox assignment    | All `UserMailbox` recipients in domain |

Each address list is filtered by `WindowsEmailAddress -like "*@$domain"` so tenants stay visually isolated from one another inside the same Exchange Online tenant.

### Catch-All Components

| Resource                   | Naming Pattern                   |
|----------------------------|----------------------------------|
| Accepted-domain change     | `DomainType = InternalRelay`     |
| Dynamic Distribution Group | `Yakala DynDistGroup - {domain}` |
| Group SMTP address         | `{CATCHALL_PREFIX}@{domain}`     |
| Transport Rule             | `Yakala TransRule - {domain}`    |
| Redirect target            | `{REDIRECT_USER}@{domain}`       |

The transport rule fires only for messages with `FromScope = NotInOrganization` whose recipient domain matches and whose recipient is not a member of the dynamic group, then redirects them to the configured `REDIRECT_USER`.

## Troubleshooting

### Connection Issues

```powershell
# Force-close any stuck Exchange Online sessions
Disconnect-ExchangeOnline -Confirm:$false

# Clear remaining remote sessions
Get-PSSession | Remove-PSSession
```

All scripts use `Connect-ExoSmart` from `_Exc-Connect.ps1`, which automatically reuses active sessions and selects the correct authentication method based on `AUTH_MODE`.

### Verify Configuration

```powershell
# Confirm accepted-domain types after catch-all setup
Get-AcceptedDomain | Select-Object DomainName, DomainType

# List Address Book Policies
Get-AddressBookPolicy | Format-Table Name, GlobalAddressList

# List catch-all transport rules
Get-TransportRule | Where-Object { $_.Name -like "Yakala*" }

# Check mailbox ABP assignment
Get-Mailbox user@domain.com | Select-Object AddressBookPolicy
```

### Common Pitfalls

- `Set-ExecutionPolicy` runs only on Windows; the scripts already guard it with `if ($IsWindows)`.
- `RecipientFilter` uses **OPATH** syntax (Exchange Online query language), not LDAP.
- The dynamic distribution group's SMTP address must be unique inside the tenant. Pick a `CATCHALL_PREFIX` that does not collide with existing mailboxes.
- After changing `DomainType` to `InternalRelay`, ensure inbound MX records still terminate at Exchange Online.
- ABP and transport rule cmdlets have no REST or Graph API equivalent; PowerShell is the only supported interface.

## Security

- Never commit `.env`; it is excluded by `.gitignore`.
- PFX and CER files live in `certs/` which is gitignored. `Exc-CertSetup.ps1` sets `chmod 600` on POSIX systems.
- CSV report files (`exc-report-*.csv`, `exc-forwarder-*.csv`, `exc-dnscheck-*.csv`, `exc-smtpauth-*.csv`, `exc-cloudflareDns-*.csv`, `exc-sync-*.csv`) are gitignored.
- All sensitive values must come from `.env`.

## License

Internal use only.
