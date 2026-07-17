# TWS Encrypted Log Decryption Tools

These tools decrypt IBKR TWS `.ibgzenc` log files. The encryption is
AES-128-CBC + HMAC-SHA256 with a per-session key.

## How it works

The Docker image includes a native JVMTI agent
(`scripts/decrypt/agent.c`, built into `/home/tws/.tws-tools/libagent.so`)
that TWS loads on every startup (`-agentpath:...` in `java-wrapper.sh`).

The agent:

1. Tries once immediately at JVM startup (usually too early — auth
   hasn't run yet).
2. Spawns a background pthread that polls `twslaunch.jclient.login.e.u()`
   every 15 s. Each time a new key is observed, the agent writes a new
   timestamped file:
   ```
   /home/tws/jts/logs/keys/key-<unix-ts>.hex
   ```
   and updates a `current` symlink to point at the latest one.

This means: **as long as TWS is running, the host can decrypt any log
ever produced by reading the right key from the persistent volume.**

## Format (TWS 10.48.x)

```
File header (40 bytes for keyId="aaa"):
  [u8  magic "IBGZENC\0"]
  [u4  writer version BE]            = 3
  [u4  reader version BE]            = 3
  [u16 IV]                           = random per file
  [u4  keyId length BE]
  [N   keyId bytes (ASCII)]

Body, repeating per chunk:
  [u4   plaintext length BE]
  [L    AES-128-CBC ciphertext]      L = ceil(plaintextLen/16)*16
  [u32  HMAC-SHA256(key, ciphertext)]

Plaintext of each chunk is raw-deflate compressed (nowrap=true).
The AES-128 key is 16 bytes, derived server-side per TWS session and
held in memory by twslaunch.jclient.login.e as field `t`.
```

## Files

| file | what it does |
|------|-------------|
| `decrypt.sh` | Decrypt a log (auto-picks the matching key) |
| `decrypt.py` | Pure-Python AES-128-CBC + HMAC-SHA256 + raw-deflate |
| `agent.c` | Native JVMTI agent (built into the Docker image) |
| `find-key.sh` | Print the current AES key |
| `copy_active_log.sh` | Pull the most recent `.ibgzenc` from the container |

## Quick start

```bash
# Decrypt the latest log pulled from the container
./copy_active_log.sh
./decrypt.sh /tmp/active.ibgzenc -o /tmp/tws.log

# Or decrypt a specific archived log
./decrypt.sh /path/to/tws.20260717.180820.ibgzenc

# Get the current key
./find-key.sh
```

`decrypt.py` picks the right key by matching the log file's mtime
against the timestamp in `key-<unix-ts>.hex`. If no key is older than
the log, it falls back to the most-recent one (the agent's `current`
symlink).

## Persistent layout

`docker-compose.yaml` mounts the host directory `~/src/ibkr/logs/` at
`/home/tws/jts/logs/` inside the container. Subdirectories:

```
~/src/ibkr/logs/
├── keys/
│   ├── key-1784315000.hex      # one per extraction, never deleted
│   ├── key-1784316000.hex
│   └── current -> key-...      # symlink to latest
└── decrypted/                   # default output dir for decrypt.sh
```

The encrypted logs themselves stay on the `tws-data` named volume
(`/home/tws/jts/oafdloimfccaidpfefaiepmggncpjjnikeekcofk/`) — pull
them with `copy_active_log.sh` or browse them on the host volume
directly via `docker volume inspect tws-data`.

## Why this works

Earlier we tried offline brute force of the heap dump for the AES key.
That didn't work because:

- The handoff's "first chunk = keyId 'aaa'" assumption was wrong;
  the keyId is in the cleartext header.
- Encrypted chunks' plaintext is zlib-deflated log data — no oracle.
- Without a known plaintext, brute force is 2^128.

The native JVMTI agent reads the key directly from the running JVM
through reflection on the runtime context (`twslaunch.jsetting.H.a()`
returns the singleton `l` instance, whose `u()` returns the AES key
`byte[]`). Polling catches the key once auth completes (typically
~10-15 seconds after startup).

## Requirements

- `gcc` (only needed if rebuilding the agent outside Docker)
- `python3` with `pycryptodome` (auto-installed via `nix-shell -p
  python3Packages.pycryptodome` if not already present)
- Docker CLI access to the `ibkr-tws-prod` container
- The host directory `~/src/ibkr/logs/` exists (created on first
  `docker compose up`)

## Security note

Anyone with read access to `~/src/ibkr/logs/keys/` can decrypt every
log ever produced by this TWS instance. Treat the directory as
sensitive as the IBKR credentials themselves.