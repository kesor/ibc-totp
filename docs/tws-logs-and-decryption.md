# TWS Encrypted Logs: End-to-End Handoff

This is the running state of the IBKR TWS container as of right now:
how to operate it, how to read encrypted logs, and what's still
broken.

## TL;DR

```bash
# Start the container
make up

# Wait for TWS to come up (~30s)
make ps

# Extract the live AES key (one per TWS session)
make extract-key

# Decrypt any log ever produced by this container
make decrypt LOG=~/src/ibkr/jts/oafdloimfccaidpfefaiepmggncpjjnikeekcofk/tws.20260717.232635.ibgzenc
```

That's the whole workflow.

## What's on disk

### Host: `~/src/ibkr/`

```
~/src/ibkr/
├── Makefile                       build / up / down / extract-key / decrypt
├── docker-compose.yaml            one service: tws → ibkr-tws-prod
├── docker/                        image build context
│   ├── Dockerfile                 nix-based image, builds the JVMTI agent
│   ├── java-wrapper.sh            /home/tws/java — the JVM launcher wrapper
│   ├── ibkr-entrypoint.sh         starts Xvfb + openbox + IBC + sleeps
│   ├── ibc-start.sh               invokes IBC with TOTP secret from secrets
│   ├── ibc-config.ini             IBC config (creds, TOTP secret)
│   ├── ibkr-entrypoint.sh         → /docker-entrypoint.sh (CMD)
│   ├── example-tws.secrets        template for tws.secrets
│   ├── tws.secrets                 NOT in git — IBKR credentials (TOTP secret)
│   └── IBC/                       patched IBC for TOTP support
├── scripts/
│   └── decrypt/
│       ├── README.md              format reference + quick-start
│       ├── decrypt.sh             end-to-end: auto-pick key + decrypt
│       ├── decrypt.py             Python AES-128-CBC + HMAC + raw-deflate
│       ├── agent.c                native JVMTI agent (built into image)
│       ├── extract-key.sh         builds agent + attaches to running TWS
│       ├── find-key.sh            print the current AES key (host side)
│       └── copy_active_log.sh     pull latest .ibgzenc out of the container
├── docs/
│   ├── DEVELOPMENT.md             (other)
│   └── tws-logs-and-decryption.md ← this document
└── jts/                           bind-mounted to /home/tws/jts in container
                                   git-ignored (user data)
```

### Container: `/home/tws/jts/`

Everything TWS writes ends up here (via the bind-mount). Layout
once TWS has been running for a while:

```
/home/tws/jts/
├── oafdloimfccaidpfefaiepmggncpjjnikeekcofk/   (per-user-dir, hash-derived)
│   ├── ads/                            binary ad images, ignorable
│   ├── audits/
│   ├── api.*.ibgzenc                  older encrypted API logs
│   ├── audit.*.ibgzenc                encrypted audit logs
│   └── tws.YYYYMMDD.HHMMSS.ibgzenc    current encrypted log files
├── launcher.log                        plaintext last-lines of TWS log
├── launcher.YYYYMMDD.log               older dated plaintext logs
├── jts.ini                             TWS settings (read by TWS at startup)
├── xmlopt.dat                          some TWS GUI state
└── logs/                               written by our scripts/agent
    ├── keys/
    │   ├── key-<unix-ts>.hex          one per TWS session
    │   └── current -> key-...          symlink to latest
    └── decrypted/                      default output dir
```

The `oafdlo.../` directory name is a per-user hash that TWS derives
from your account at first login. Don't hardcode it — use a glob.

## Architecture

```
   ┌──────── host ─────────┐                ┌──── container ──────┐
   │                       │                │                     │
   │  ~/src/ibkr/jts/  ◄═══│════════════════│═►  /home/tws/jts/  │
   │  (bind-mount)        │                │  (TWS data dir)    │
   │                       │                │                     │
   │  encrypted logs       │                │  /home/tws/.tws-tools/
   │  plaintext logs       │                │    libagent.so      │
   │  key archive          │  ◄─── agent ───│─── (built into image)
   │                       │     writes     │                     │
   │                       │                │  ibcrun → /home/tws/java
   │                       │                │    (wrapper, exec's
   │                       │                │     /root/.nix-profile/bin/java)
   │                       │                │                     │
   │  extract-key.sh       │  ─── docker ──►│──► jcmd JVMTI.agent_load
   │  decrypt.py           │     exec       │    /tmp/libagent.so
   │                       │                │                     │
   └───────────────────────┘                └─────────────────────┘
```

## Encryption format

TWS 10.48.x with IbgzencVersion 3. Verified by reading
`scripts/decrypt/agent.c` and `decrypt.py`.

```
File header:
  [u8  magic "IBGZENC\0"]            (8 bytes)
  [u4  writer version BE]            (= 3)
  [u4  reader version BE]            (= 3)
  [u16 IV]                           (16 bytes, SecureRandom per file)
  [u4  keyId length BE]
  [N   keyId bytes (ASCII)]          (e.g. "aaa", cleartext)

Body, repeating per chunk:
  [u4   plaintext length BE]         (length BEFORE encryption)
  [L    AES-128-CBC ciphertext]      (L = ceil(plaintextLen/16)*16)
  [u32  HMAC-SHA256(key, ciphertext)]

Plaintext of each chunk:
  raw-deflate compressed (nowrap=true, wbits=-15)

Encryption:
  AES/CBC/PKCS5Padding (SunJCE), 16-byte key
  HMAC-SHA256 (SunJCE), same 16-byte key as a MAC key
```

The IV is per-file (SecureRandom). The key is per-session: TWS
receives a Base64 string from the IB auth server during the
`NS_FIX_START` handshake, decodes it via `jutils.crypt.b.a(String)`
(= `Base64.getDecoder()`), and stores it as `byte[]` in field `t`
of `twslaunch.jclient.login.e`. The same key is used for all
files in a session.

## How decryption works

1. **`scripts/decrypt/agent.c`** — native JVMTI agent. Builds
   against the container's `zulu21` JDK. When attached to a
   running TWS JVM, it:
   - Spawns a background pthread that polls
     `twslaunch.jclient.login.e.u()` every 15 s (with a 3-second
     startup delay to avoid a TLAB-init crash window).
   - Each new key gets written as `key-<unix-ts>.hex` to
     `/home/tws/jts/logs/keys/`.
   - Updates the `current` symlink to point at the latest key.
   - Deduplicates so unchanged keys don't spam the archive.

2. **`scripts/decrypt/extract-key.sh`** — host script that:
   - Finds the running TWS JVM (`jcmd | grep IbcTws`).
   - Builds `libagent.so` from `agent.c` if missing.
   - Copies the agent into the container.
   - Attaches via `jcmd JVMTI.agent_load /tmp/libagent.so`.
   - Waits for the agent to write the key, then verifies it
     appears at the host bind-mount path.

3. **`scripts/decrypt/decrypt.sh`** — picks the right key for a
   given log file by matching mtimes:
   ```python
   best = max(key for key in keys_dir if key.mtime <= log.mtime)
   ```
   Falls back to `current` symlink if no key is older than the
   log. Then runs `decrypt.py`.

4. **`scripts/decrypt/decrypt.py`** — pure-Python AES-128-CBC +
   HMAC-SHA256 + raw-deflate. Verifies the HMAC per chunk;
   bails on the first mismatch with a clear error message.

## What works

- `make up` builds the image (Nix-based, takes ~5 min cold,
  ~30s warm) and starts the container with the bind-mount.
- TWS authenticates with TOTP via the IBC patches (`ibcsessionid`
  is set by IBC's `--ibcsessionid` flag).
- `make extract-key` works on a freshly-started TWS within
  ~3 seconds of the JVM coming up.
- `make decrypt LOG=...` correctly picks the key by mtime, and
  decrypts in a few seconds.
- Keys accumulate in `~/src/ibkr/jts/logs/keys/` indefinitely.
- The host can decrypt any historical log ever produced by this
  container, as long as the key was extracted for that session.

## What's broken / known limitations

### 1. Auto-loading the JVMTI agent at JVM startup crashes TWS

If we add `-agentpath:/home/tws/.tws-tools/libagent.so` to TWS's
JVM args via `docker/java-wrapper.sh`, TWS crashes during
`Threads::create_vm` with SIGSEGV. The crash signature:

```
V  [libjvm.so+0xf909a6]  ThreadLocalAllocBuffer::initial_desired_size()+0xb6
```

The same agent binary works fine when attached via
`jcmd JVMTI.agent_load` AFTER TWS is fully running. The
difference between the two attach paths is unclear. Possibly
related to TLAB / JIT initialization timing.

**Workaround**: `java-wrapper.sh` defaults to `IBC_DISABLE_AGENT=1`,
so the agent is NOT auto-loaded. We manually attach via
`make extract-key` after `make up`. This works fine.

**If you want to try auto-loading**: set `IBC_DISABLE_AGENT=0` in
`docker/java-wrapper.sh`, rebuild, and `make up`. TWS will
crash-loop. Capture the resulting hs_err_pid*.log files and
compare their stacks — the `ThreadLocalAllocBuffer::initial_desired_size`
sigtrap is the same symptom.

### 2. Charts (advanced charts, tradingview) still don't render

This was the ORIGINAL problem that prompted this investigation.
Root cause: the `zulu21` Nix package's wrapper doesn't put X11 client
libraries on `LD_LIBRARY_PATH`, so AWT's XToolkit fails to dlopen
`libX11.so.6`. Symptom: "No toolkit found", embedded HTTP bridge on
port 20000 never starts, anything depending on it (advanced
charts, calendar, etc.) hangs at "Loading...".

**Fix already applied** (in the same Dockerfile):
- Installed `libX11`, `libXext`, `libXtst`, `libXi`, `libXrender`,
  `libXt`, `libXdmcp`, `libXau` into the image.
- `java-wrapper.sh` prepends `/root/.nix-profile/lib` to
  `LD_LIBRARY_PATH` before `exec java`.

**Status**: untested. The current container has been crashing
before we could verify whether the chart rendering now works.
The earlier SIGSEGVs in TWS startup were the same chart-related
crash (TWS tries to load the chart rendering pipeline, hits
missing libX11, segfaults). With the new image, charts *should*
work — but the auto-load crash is masking this verification.

### 3. The bind-mount host dir needs uid 1000

If your host user isn't uid 1000, the in-container `tws` user
(uid 1000) can't write to `~/src/ibkr/jts/`. Symptom: TWS can't
write its jts.ini, IBC retries forever.

**Fix**: ensure your host user has uid 1000, OR chmod the dir
manually after first start:
```bash
sudo chown -R 1000:1000 ~/src/ibkr/jts/
```

### 4. Decrypted output dir lives inside the bind-mount

`decrypt.sh` defaults to writing next to the encrypted file
(in `~/src/ibkr/jts/oafdlo.../tws.YYYYMMDD.HHMMSS.log`). This
works because the bind-mount is writable. If you prefer
decrypted logs in a separate location, pass `-o /some/path`.

## Makefile targets

```bash
make build         # build the docker image
make up            # start the container
make down          # stop and remove the container
make restart       # restart the container (preserves jts bind-mount)
make logs          # tail container stdout
make ps            # show running containers
make extract-key   # attach agent to running TWS, write key to host
make decrypt LOG=path/to/log.ibgzenc
                   # auto-pick key, decrypt, write next to input
```

## Operation flow

### Fresh start

```bash
mkdir -p ~/src/ibkr/jts/
cd ~/src/ibkr
make build           # ~5 min first time, ~30s warm
make up
# Wait until TWS is running:
make ps
# Look for "ibkr-tws-prod" running
```

### Extract the AES key

```bash
make extract-key
# output:
#   TWS Java PID: 5643
#   Key file (container): /home/tws/jts/logs/keys/key-1784319997.hex
#   Key: d1ce3c0bab41c0e23c0ad1ebc498fa42
#   Written to /tmp/tws-log-key.hex
#   Also available on host at ~/src/ibkr/jts/logs/keys/key-1784319997.hex
```

After TWS restarts (next day, weekly TWS scheduled restart, crash
recovery, etc.), run `make extract-key` again to get the new key.
Old keys are preserved.

### Decrypt a log

```bash
# Find a log:
ls -lt ~/src/ibkr/jts/oafdloimfccaidpfefaiepmggncpjjnikeekcofk/tws.*.ibgzenc

# Decrypt (auto-picks the right key):
make decrypt LOG=~/src/ibkr/jts/oafdloimfccaidpfefaiepmggncpjjnikeekcofk/tws.20260717.232635.ibgzenc

# Output: ~/src/ibkr/jts/oafdloimfccaidpfefaiepmggncpjjnikeekcofk/tws.20260717.232635.log
```

### Daily / weekly operations

TWS restarts itself (the IBC config can do autorestart; see
`AutoRestartTime` in `docker/ibc-config.ini`). After each
restart, the key changes. Workflow:

```bash
# After a TWS restart (or `make restart`):
make extract-key    # get the new key

# Now you can decrypt the log from THIS session.
# Old logs from previous sessions need their respective keys,
# which are still on disk in ~/src/ibkr/jts/logs/keys/.
```

## Known debugging commands

```bash
# Is TWS running?
docker exec ibkr-tws-prod /root/.nix-profile/bin/jcmd | grep IbcTws

# What's the current TWS JVM command line?
docker exec ibkr-tws-prod /root/.nix-profile/bin/jcmd <pid> Thread.print | head -3

# What keys do we have?
ls -lt ~/src/ibkr/jts/logs/keys/

# Most recent agent trace:
docker exec ibkr-tws-prod sh -c 'ls -t /tmp/agent-trace-* | head -1 | xargs cat'

# Latest crash log (if any):
docker exec ibkr-tws-prod sh -c 'ls -t /home/tws/jts/hs_err_*.log 2>/dev/null | head -1 | xargs grep -A 3 "Problematic frame"'
```

## Future work

1. **Root-cause the `-agentpath:` startup crash.** With the fix
   in place, the chart-rendering fix in the same Dockerfile
   could be verified. Capture an hs_err dump from a startup
   crash (set `IBC_DISABLE_AGENT=0`, `make up`, then look in
   `~/src/ibkr/jts/hs_err_pid*.log`).

2. **Verify charts render.** Once startup crash is fixed, open
   VNC (`vnc://localhost:5901`), open a chart in TWS, watch for
   the "Loading..." spinner to disappear.

3. **Optionally enable TWS autorestart** in IBC config
   (`AutoRestartTime=23:00`) so the chart-related crashes
   self-heal.

## Git history

```
34d91  Bind-mount /home/tws/jts and fix entrypoint timestamp bug
93903  Bake the log-key JVMTI agent into the image
ba8a4  Add tools for decrypting TWS .ibgzenc encrypted logs
f0c57  make browser work and add fonts
452ac  use ungoogled chromium
```

The first three are this work; the last two are the prior browser
work. `jts/` is git-ignored — user data must not be committed.