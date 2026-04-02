# Development & Installation Guide

This guide covers:
1. Docker deployment setup
2. Building IBC from source
3. Development environment with Nix
4. Configuration reference

## Prerequisites

- **Docker** (20.10+) and Docker Compose
- **Make** (optional, for convenience commands)
- **Git**
- For development: **Nix** (for reproducible builds)

## Docker Deployment Setup

### 1. Clone the Repository

```bash
git clone <this-repo-url>
cd ibkr
```

### 2. Create Credentials File

Create `docker/tws.secrets`:

```bash
TWS_USERNAME=your_ibkr_username
TWS_PASSWORD=your_ibkr_password
TWS_TOTP_SECRET=your_base32_totp_secret
```

> ⚠️ **SECURITY**: Run `chmod 600 docker/tws.secrets` to restrict access.

### 3. Get Your TOTP Secret

1. Log into IBKR Account Management
2. Go to Settings → Security → Secure Login System
3. If you have mobile authenticator setup, look for option to view secret
4. The secret is Base32 encoded (letters A-Z, digits 2-7)
5. Example: `JBSWY3DPEHPK3PXP`

### 4. Configure IBC

Edit `docker/ibc-config.ini` as needed:

```ini
# Trading mode: live or paper
TradingMode=live

# API port
OverrideTwsApiPort=7496

# Auto-restart settings
AutoLogoffTime=06:45 AM
AutoRestartTime=07:00 AM

# Security settings
AcceptIncomingConnectionAction=accept
AllowBlindTrading=yes
```

### 5. Build and Run

```bash
# Using Make
make build
make up

# Or directly
cd docker
docker compose up -d
```

### 6. Verify

```bash
# Check container is running
docker compose ps

# View logs
make logs

# Tail IBC output
docker exec ibkr-tws-prod tail -f /home/tws/ibc-out-*.log
```

## Accessing TWS

| Service | Address | Description |
|---------|---------|-------------|
| VNC | `localhost:5901` | Full desktop access |
| API (live) | `localhost:7496` | Trading API |
| API (paper) | `localhost:7497` | Paper trading API |

Connect to VNC with any VNC client (no password by default).

## Building IBC from Source

This project includes a modified IBC with TOTP support. To rebuild:

### Using Nix (Recommended)

```bash
# Enter dev shell (auto-downloads TWS on first run)
nix develop

# Build IBC
cd IBC && ant dist
```

The `nix develop` command:
- Installs ant, openjdk21, curl, unzip
- Downloads TWS standalone installer
- Patches it to use system Java
- Extracts required jars to `tws-jars/1044/jars/`

### Nix Commands

```bash
nix develop              # Enter dev shell with all tools
nix develop -c ant dist  # Build without entering shell
nix flake update         # Update nixpkgs input
```

### Build Targets

```bash
cd IBC
ant compile    # Compile → IBC/target/classes
ant jar       # Create IBC.jar in IBC/resources/
ant dist      # Create Linux/Windows/Macos zip files
```

### Copy Built Files to Docker

```bash
./scripts/download-deps.sh docker
cp IBC/resources/IBC.jar docker/IBC/
cp IBC/lib/*.jar docker/IBC/lib/
cp -r IBC/resources/scripts docker/IBC/
```

Or use the convenience script:

```bash
./scripts/download-deps.sh docker
```

## Development Workflow

### Quick Rebuild Cycle

```bash
# 1. Edit source in IBC/
vim IBC/src/...

# 2. Compile
cd IBC && ant compile

# 3. Test locally
./IBC/scripts/ibcstart.sh

# 4. When ready, build full distribution
ant dist
```

### Running Without Docker

You can run IBC directly on a Linux/macOS machine:

```bash
# Install dependencies
sudo apt install openjdk-21-jre xterm xvfb

# Download TWS (standalone offline version)
# Extract to ~/Jts

# Configure
cp docker/ibc-config.ini ~/.ibc/config.ini
vim ~/.ibc/config.ini  # Set IbLoginId, IbPassword

# Run
cd docker/IBC
./scripts/ibcstart.sh
```

## Configuration Reference

### docker/tws.secrets

| Variable | Required | Description |
|----------|----------|-------------|
| `TWS_USERNAME` | Yes | IBKR account username |
| `TWS_PASSWORD` | Yes | IBKR account password |
| `TWS_TOTP_SECRET` | Yes | Base32 TOTP secret for 2FA |

### docker/ibc-config.ini

| Setting | Default | Description |
|---------|---------|-------------|
| `TradingMode` | `live` | `live` or `paper` |
| `OverrideTwsApiPort` | `7496` | API port |
| `AcceptIncomingConnectionAction` | `accept` | Auto-accept API connections |
| `AllowBlindTrading` | `yes` | Auto-accept blind trading |
| `AutoLogoffTime` | `06:45 AM` | Daily logoff |
| `AutoRestartTime` | `07:00 AM` | Daily auto-restart |
| `TwsTotpSecret` | (empty) | TOTP secret (alternative to secrets file) |

For full config options, see the sample `config.ini` in the IBC source.

## Upgrading IBC

### When to Upgrade

- New IBC version has features you need
- Security patches
- Bug fixes

### Upgrade Steps

1. **Download new IBC release**:
   ```bash
   cd ..
   git clone https://github.com/IbcAlpha/IBC.git IBC-new
   ```

2. **Apply our TOTP patch**:
   ```bash
   cd IBC-new
   git am < ../ibkr/ibc-patches/ibc-patch-totp.patch
   ```

3. **Download dependencies**:
   ```bash
   ./ibkr/scripts/download-deps.sh ibc
   ```

4. **Build**:
   ```bash
   ant clean dist
   ```

5. **Copy to project**:
   ```bash
   cp resources/IBC.jar ../ibkr/docker/IBC/
   cp lib/*.jar ../ibkr/docker/IBC/lib/
   cp -r resources/scripts ../ibkr/docker/IBC/
   ```

6. **Replace IBC source in project**:
   ```bash
   rm -rf ../ibkr/IBC
   mv ../IBC-new ../ibkr/IBC
   ```

7. **Rebuild Docker image**:
   ```bash
   cd ../ibkr/docker
   docker compose build
   docker compose up -d
   ```

## Project Structure

```
ibkr/
├── docker/                      # Docker deployment
│   ├── Dockerfile              # Container image
│   ├── docker-compose.yaml     # Container orchestration
│   ├── tws.secrets            # Credentials (NOT committed!)
│   ├── ibc-config.ini          # IBC configuration
│   ├── ibkr-entrypoint.sh     # Container entrypoint
│   ├── ibc-start.sh           # IBC + TWS launcher
│   └── IBC/                   # Built IBC with TOTP support
│       ├── IBC.jar
│       ├── lib/               # googleauth-*.jar
│       └── scripts/
├── IBC/                        # IBC source (forked from upstream)
│   ├── src/                   # Java source
│   ├── build.xml              # Ant build file
│   ├── resources/             # IBC.jar output
│   └── dist/                  # Distribution zip files
├── ibc-patches/               # Patches applied to upstream IBC
│   └── ibc-patch-totp.patch  # TOTP support patch
├── scripts/
│   └── download-deps.sh       # Download external libs
├── flake.nix                  # Nix dev environment
└── DEVELOPMENT.md             # This file
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker compose logs

# Check if ports are in use
lsof -i :5901
lsof -i :7496
```

### TWS Login Fails

1. Verify credentials in `docker/tws.secrets`
2. Check TOTP secret is correct (Base32, no spaces)
3. Try paper trading mode first:
   ```ini
   TradingMode=paper
   ```
4. Check logs for specific error messages

### VNC Connection Refused

```bash
# Wait for container to fully start (can take 1-2 minutes)
sleep 120
docker compose restart
```

### API Connection Issues

1. Ensure `AcceptIncomingConnectionAction=accept` in config
2. Check firewall rules for port 7496/7497
3. For local testing, use `localhost`, not `127.0.0.1`

## See Also

- [IBC GitHub](https://github.com/IbcAlpha/IBC) - Upstream project
- [IBC User Guide](IBC/userguide.md) - Full IBC documentation
- [IBC User Group](https://groups.io/g/ibcalpha) - Community support
