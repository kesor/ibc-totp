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

1. **Use a secrets management solution** (e.g., HashiCorp Vault, AWS Secrets Manager)
2. **Enable IP restrictions** on your IBKR account
3. **Use a dedicated paper trading account** for automation, never your live trading account
4. **Restrict file permissions**: `chmod 600 docker/tws.secrets`
5. **Never commit this file to version control** (it should be gitignored)
6. **Consider environment-specific secrets** with rotation policies

### Docker Secrets Limitation

**Docker secrets are stored in plaintext** in `/var/lib/docker/swarm/secrets/` (for Swarm) or as environment variables (for Compose), and are **readable by any process on the host**. Do NOT use this setup for production live trading without additional security layers.

---

# IBKR TWS Docker Setup

Runs Interactive Brokers' Trader Workstation (TWS) in a Docker container with IBC controller for automated, hands-free trading.

## What This Is

This project containerizes:
- **Trader Workstation (TWS)** - IBKR's trading platform
- **IBC** (Interactive Brokers Controller) - Automates TWS login and dialog handling
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
cd docker
docker compose up -d
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
| **DEVELOPMENT.md** | Full setup, installation, and development guide |

## What's Inside

```
ibkr/
├── docker/              # Docker deployment
│   ├── Dockerfile       # Container build
│   ├── docker-compose.yaml
│   ├── tws.secrets     # Credentials (gitignored!)
│   ├── ibc-config.ini  # IBC settings
│   └── IBC/            # Built IBC with TOTP support
├── IBC/                # IBC source (upstream fork with TOTP patch)
├── ibc-patches/        # Source patches
├── scripts/            # Helper scripts
└── flake.nix           # Nix dev environment
```
