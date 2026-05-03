# ⚠️ SECURITY WARNING ⚠️

## DO NOT STORE CREDENTIALS IN PLAINTEXT FILES

**This repository requires storing your IBKR password AND TOTP secret together in a single file.**

This is an **EXTREMELY DANGEROUS** security practice because:

| Credential | Risk |
|------------|------|
| Password | Account access if file is compromised |
| TOTP Secret | **Allows generating valid 2FA codes**, defeating the second authentication factor |

**If an attacker obtains `docker/tws.secrets`, they have complete access to your trading account.**

### Mitigation Recommendations

For production use, you **must** implement additional security layers beyond just protecting the secrets file:

#### 1. Use a Separate Paper Trading Account (Recommended)

Create a dedicated paper trading account for automation. Store separate, paper-trading-only credentials in `docker/tws.secrets`. This limits damage if credentials are compromised to paper trading only.

**Related documentation:**
- [IBKR Paper Trading](https://www.interactivebrokers.com/lib/cstools/faq/#/content/37128282)

#### 2. Use a Dedicated Automation User with Restricted Permissions (Limited Protection)

You can create additional users for your account with granular permissions. Note: Individual accounts are limited to **two usernames** for the same person.

**Setup steps:**
1. Create a dedicated automation user: `Settings → Account Settings → Users & Access Rights → Users → Add (+)` [^1]
2. Assign a restricted user role or customize permissions [^2]
3. Disable funding access (withdrawals, position transfers) [^3]
4. Set IP restrictions to your server's IP only [^4]

**Important caveats:**
- An attacker with credentials **could potentially modify their own permissions** unless the system requires additional verification
- Changes to IP restrictions take effect the **next business day**

**Related documentation:**
- [Users & Access Rights](https://www.ibkrguides.com/clientportal/uar/userandaccessrights.htm)
- [Adding a User](https://www.ibkrguides.com/clientportal/uar/addingauser.htm)
- [User Roles](https://www.ibkrguides.com/clientportal/uar/userroles.htm)
- [User Access Rights Definitions](https://www.ibkrguides.com/clientportal/uar/uardefinitions.htm)
- [Funding Access Permissions](https://www.ibkrguides.com/clientportal/uar/uardefinitions.htm#funding-access)

#### 3. Enable IP Restrictions

Restrict trading platform access (TWS, Mobile, Portal Trade) to specific IP addresses. Access from non-whitelisted IPs is limited to administrative functions only.

⚠️ **Note:** Adding or removing IP restrictions takes effect the **following business day**.

**Related documentation:**
- [IP Restrictions](https://www.ibkrguides.com/clientportal/usersettings/iprestrictions.htm)

#### 4. Configure A/B Authorization (Dual Control)

Require approval from a separate authorized user for funding requests. The automation user can submit requests, but a Primary Authorizer must approve them.

**Related documentation:**
- [Authorizers](https://www.ibkrguides.com/clientportal/uar/authorizers.htm)
- [Account Withdrawal Limits](https://www.ibkrguides.com/clientportal/sls/withdrawallimits.htm)

#### 5. Use a Secrets Management Solution

- HashiCorp Vault, AWS Secrets Manager, or similar
- Rotate credentials regularly
- Never commit secrets to version control

#### 6. File Permissions

```bash
chmod 600 docker/tws.secrets
```

### Docker Secrets Limitation

**Docker secrets are stored in plaintext** in `/var/lib/docker/swarm/secrets/` (for Swarm) or as environment variables (for Compose), and are **readable by any process on the host**. Do NOT use this setup for production live trading without additional security layers.

---

# IBKR TWS Docker Setup

Runs Interactive Brokers' Trader Workstation (TWS) in a Docker container with IB Controller for automated, hands-free trading.

## What This Is

This project containerizes:
- IBKR's [**Trader Workstation (TWS)**](https://www.interactivebrokers.com/en/trading/download-tws.php?p=offline-stable) - trading platform
- [**IBC** (Interactive Brokers Controller)](https://github.com/IbcAlpha/IBC/) - Automates TWS login and dialog handling
- **Automatic 2FA** - TOTP code generation for hands-free login
- **VNC Access** - Remote desktop via port 5901
- **X11/Xvfb** - Headless GUI operation

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Docker Container                    │
│                                                         │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌───────┐ │
│  │  Xvfb   │───▶│ Openbox │───▶│  Tint2  │───▶│ x11vnc│ │
│  └─────────┘    └─────────┘    └─────────┘    └───────┘ │
│       │                                                 │
│       ▼                                                 │
│  ┌─────────────────────────────────────────────────┐    │
│  │              IBC (Java Controller)              │    │
│  │  • Login automation (user/password/TOTP)        │    │
│  │  • Dialog handlers (API, warnings, etc)         │    │
│  │  • Session management                           │    │
│  └─────────────────────┬───────────────────────────┘    │
│                        │                                │
│                        ▼                                │
│  ┌─────────────────────────────────────────────────┐    │
│  │         TWS / Gateway (Java Application)        │    │
│  │  • Trading platform                             │    │
│  │  • API server (port 7496)                       │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
└─────────────────────────────────────────────────────────┘
         │                                    │
         │                                    ▼
    Port 5901                           Port 7496
    (VNC)                              (API)
```

## Quick Start

> ⚠️ **SECURITY WARNING**: Before continuing, read the security warning at the top of this file.
> 
> **For development/testing only** - never use your primary trading account.

### 1. Configure Secrets

Create `docker/tws.secrets`:

```bash
TWS_USERNAME=your_username
TWS_PASSWORD=your_password
TWS_TOTP_SECRET=your_base32_totp_secret
```

**Use `chmod 600 docker/tws.secrets` to restrict file access.**

### 2. Run

```bash
docker compose up -d
```

The Xvfb desktop defaults to **1920×1080**. To pick a different size,
set `VNC_RESOLUTION` (`WIDTHxHEIGHT`):

```bash
VNC_RESOLUTION=1280x800 docker compose up -d
```

### 3. Access

- **VNC**: Connect to `localhost:5901`
- **API**: Connect to `localhost:7496` (live) or `localhost:7497` (paper)

## Access Ports

| Port | Service | Description |
|------|---------|-------------|
| 5901 | VNC | Remote desktop access |
| 7496 | API | TWS API (live trading) |
| 7497 | API | TWS API (paper trading) |

## Security Notes

> ⚠️ **READ THE SECURITY WARNING AT THE TOP OF THIS FILE.**

- The `docker/tws.secrets` file contains your IBKR password AND TOTP secret
- If compromised, an attacker has complete account access
- Docker secrets are **not encrypted** - readable by any process with Docker socket access
- For production: use paper trading, enable IP restrictions, firewall ports

## Documentation

| Document | Purpose |
|----------|---------|
| **[DEVELOPMENT.md](DEVELOPMENT.md)** | Full setup, installation, and development guide |

## What's Inside

```
ibc-totp/
├── docker/              # Docker deployment
│   ├── Dockerfile       # Container build
│   ├── tws.secrets      # Credentials (gitignored!)
│   ├── ibc-config.ini   # IBC settings
│   └── IBC/             # Built IBC with TOTP support
├── IBC/                 # IBC source (upstream fork with TOTP patch)
├── ibc-patches/         # Source patches
├── scripts/             # Helper scripts
├── docker-compose.yaml  # Container orchestration
└── flake.nix            # Nix dev environment
```

---

[^1]: Individual accounts are limited to two usernames for the same person. See [Adding a User](https://www.ibkrguides.com/clientportal/uar/addingauser.htm) for details.

[^2]: User Roles let you define reusable permission templates. See [User Roles](https://www.ibkrguides.com/clientportal/uar/userroles.htm) for details.

[^3]: Funding access can be configured per-user. See [User Access Rights Definitions - Funding Access](https://www.ibkrguides.com/clientportal/uar/uardefinitions.htm#funding-access) for details.

[^4]: IP restrictions apply to trading platforms only. Administrative portal access may still be available from other IPs. See [IP Restrictions](https://www.ibkrguides.com/clientportal/usersettings/iprestrictions.htm) for details.
