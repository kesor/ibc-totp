# IBC Patches

This folder contains patches applied to the upstream [IBC](https://github.com/IbcAlpha/IBC) source.

## Patches

### ibc-patch-totp.patch

Adds automatic TOTP (Time-based One-Time Password) generation for 2FA login.

**What it does:**
- Detects "Mobile Authenticator app" prompts during login
- Generates 6-digit TOTP codes using the `googleauth` library
- Auto-fills the code and clicks OK to complete login

**Required library:**
- `googleauth-1.5.0.jar` in `IBC/lib/` (download via `./scripts/download-deps.sh ibc`)

## Creating New Patches

After making changes to IBC source:

```bash
cd IBC
git add -A
git commit -m "Your commit message"
git format-patch -1 --stdout > ../ibkr/ibc-patches/ibc-patch-description.patch
```

## For Full Upgrade Instructions

See [DEVELOPMENT.md](../DEVELOPMENT.md#upgrading-ibc)
