# TWS Encrypted Log Decryption Tools

These tools decrypt IBKR TWS `.ibgzenc` log files. The encryption is
AES-128-CBC + HMAC-SHA256 with a per-session key.

## How it works

The Docker image includes a native JVMTI agent
(`scripts/decrypt/agent.c`, built into `/home/tws/.tws-tools/libagent.so`)
that, when attached to a running TWS JVM, polls the runtime context
for the live AES-128 logKey and writes timestamped key files.

The agent is **disabled by default at JVM startup** (see
`IBC_DISABLE_AGENT=1` in `docker/java-wrapper.sh`). The combination
of Zulu OpenJDK 21 + TWS 10.48 + `-agentpath:` crashes the JVM
during `Threads::create_vm` with SIGSEGV. The same agent works
fine when attached AFTER TWS is fully running.

Workflow after `make up`:

```bash
# 1. TWS is running. Attach the agent to get the live key.
make extract-key

# 2. Decrypt a log (auto-picks the right key by mtime).
make decrypt LOG=~/src/ibkr/jts/oafdlo.../tws.YYYYMMDD.HHMMSS.ibgzenc
```

Or directly:

```bash
./scripts/decrypt/extract-key.sh
./scripts/decrypt/decrypt.sh /path/to/log.ibgzenc
```

The agent, when attached:

1. Spawns a background pthread that polls `twslaunch.jclient.login.e.u()`
   every 15 s (after a 3-second startup delay). Each time a new key is
   observed, the agent writes a new timestamped file:
   ```
   /home/tws/jts/logs/keys/key-<unix-ts>.hex
   ```
   and updates a `current` symlink to point at the latest one.
2. Deduplicates: if the key hasn't changed since the last poll, no
   new file is written. The keys archive grows once per TWS session.
3. Writes a unique trace file `/tmp/agent-trace-<pid>-<ts>.log` per
   attach (avoids races with external cleanup).

`docker-compose.yaml` bind-mounts the host directory `~/src/ibkr/jts/`
at `/home/tws/jts/` inside the container, so everything TWS writes
(encrypted logs, keys, settings, jts.ini, ...) ends up on the host.
**As long as TWS is running, the host can decrypt any log ever
produced.**

## Persistent layout

```
~/src/ibkr/jts/                         (the bind-mount target on host)
├── <per-user-hash>/                    (created by TWS at first run)
│   ├── ads/                            (binary ad images, ignorable)
│   ├── audits/
│   ├── api.*.ibgzenc                  # older encrypted API logs
│   └── tws.YYYYMMDD.HHMMSS.ibgzenc    # current encrypted log file(s)
├── launcher.log                        # plaintext last-lines of TWS log
├── launcher.YYYYMMDD.log               # older dated plaintext logs
├── jts.ini                             # TWS settings
└── logs/                               # written by our agent/script
    ├── keys/
    │   ├── key-1784315000.hex          # one per TWS session, never deleted
    │   ├── key-1784316000.hex
    │   └── current -> key-...          # symlink to latest
    └── decrypted/                      # default output dir for decrypt.sh
```

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
| `extract-key.sh` | Attach the agent to running TWS, write key to disk |
| `find-key.sh` | Print the current AES key |
| `copy_active_log.sh` | Copy the most recent `.ibgzenc` to `/tmp/` |

## Quick start

```bash
# Decrypt the most recent log
./copy_active_log.sh
./decrypt.sh /tmp/active.ibgzenc -o /tmp/tws.log

# Decrypt a specific archived log directly from the host
./decrypt.sh ~/src/ibkr/jts/oafdloimf.../tws.20260717.180820.ibgzenc

# Get the current key
./find-key.sh

# List all historical keys
ls -lt ~/src/ibkr/jts/logs/keys/
```

`decrypt.py` picks the right key by matching the log file's mtime
against the timestamp in `key-<unix-ts>.hex`. If no key is older than
the log, it falls back to the most-recent one (the agent's `current`
symlink).

## Setup

If you're setting this up for the first time:

1. Make sure `~/src/ibkr/jts/` exists and is owned by your user
   (the in-container `tws` user has uid 1000, so your host user must
   also be uid 1000 for writes to work):
   ```bash
   mkdir -p ~/src/ibkr/jts
   ```

2. `make down && make up` to recreate the container with the new
   bind-mount. The first start will be a clean TWS session — the old
   named volume data (`tws-data`) is preserved by Docker but no
   longer mounted; you can `docker volume rm ibkr_tws-data` to clean
   it up later.

3. Wait ~30 seconds for TWS to authenticate. Then:
   ```bash
   ls ~/src/ibkr/jts/logs/keys/
   # should show key-<ts>.hex and `current` symlink
   ```

4. Copy any old `*.ibgzenc` files you want to keep from the old
   named volume (if you care):
   ```bash
   docker run --rm -v ibkr_tws-data:/from -v ~/src/ibkr/jts:/to \
       alpine sh -c 'cp -a /from/oafdloimf.../. /to/oafdloimf.../ 2>/dev/null'
   ```
   (Requires `sudo` access on the host to inspect the named volume
   directly.)

## Why this works

Earlier we tried offline brute force of the heap dump for the AES
key. That didn't work because:

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
- Host user uid = 1000 (matches the in-container `tws` user)
- The host directory `~/src/ibkr/jts/` exists

## Security note

Anyone with read access to `~/src/ibkr/jts/logs/keys/` can decrypt
every log ever produced by this TWS instance. Treat the directory as
sensitive as the IBKR credentials themselves.