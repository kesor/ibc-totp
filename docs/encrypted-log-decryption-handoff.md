# TWS Encrypted Log Decryption

## What this is

TWS `.ibgzenc` log files are AES-128-CBC + HMAC-SHA256 encrypted with
a per-session key held in the running JVM. This directory contains
the tools to extract that key and decrypt any historical log.

## How it works (current production setup)

The Docker image bakes in a native JVMTI agent
(`scripts/decrypt/agent.c`, built to `/home/tws/.tws-tools/libagent.so`).
TWS is started with `-agentpath:/home/tws/.tws-tools/libagent.so` (set
in `docker/java-wrapper.sh`), so the agent loads on every JVM start.

The agent:

1. Tries once at attach time (almost always too early — auth hasn't
   run yet, `twslaunch.jclient.login.e.t` is null).
2. Spawns a background pthread that polls every 15 s. Each time it
   sees a new key, it writes a fresh file:
   ```
   /home/tws/jts/logs/keys/key-<unix-ts>.hex
   ```
   and updates a `current` symlink to point at the latest.
3. Deduplicates: if the key hasn't changed since the last poll, no
   new file is written. The keys archive grows once per TWS session.

`docker-compose.yaml` mounts the host directory `../logs/` at
`/home/tws/jts/logs/`, so all keys (and any decrypted logs) are
visible on the host. Old keys persist indefinitely, so old log files
can always be matched with their key.

## Decrypting a log

```bash
# Default: auto-pick the key from ~/src/ibkr/logs/keys/ based on
# the log file's mtime.
./decrypt.sh /path/to/tws.YYYYMMDD.HHMMSS.ibgzenc

# Output goes to <path>.log by default. Override with -o.
./decrypt.sh /path/to/log.ibgzenc -o /tmp/today.log

# Manually pick a key:
./decrypt.sh /path/to/log.ibgzenc -k d1ce3c0bab41c0e23c0ad1ebc498fa42
```

`decrypt.py` picks the right key by:

1. Reading `key-*.hex` files in the keys dir.
2. Picking the one with the largest `unix-ts` filename suffix that is
   ≤ log file mtime.
3. Falling back to `current` symlink (or the most-recent key file) if
   no key is older than the log.

## What didn't work (history)

The first attempt assumed a known-plaintext attack on the first
encrypted chunk of the file, treating the keyId `"aaa"` as the first
16 bytes of plaintext (after PKCS5 padding). This was wrong:

- The keyId `"aaa"` is in the **cleartext header**, not the first
  encrypted chunk.
- The first encrypted chunk's plaintext is zlib-raw-deflated log
  data — no oracle at all.

A 390 MB heap dump was brute-forced twice (24M candidates each) for
`length=0x10` prefix patterns. Zero hits. The AES key wasn't sitting
in the heap as a flat byte[] (the defensive-copy logic in
`twslaunch.jclient.login.e.a(byte[])` and `u()` keeps it out of the
length-prefix pattern). Without a known-plaintext oracle, pure
offline brute force is 2^128 — not feasible.

The agent approach is the right path: read the key directly from the
running JVM through reflection on the runtime context.

## Why a native agent, not a Java agent JAR

A pure-Java agent JAR never worked because OpenJDK's attach loader
calls `Agent_OnAttach` (a JNI native entry point) **before** invoking
any Java `agentmain` method. Without `Agent_OnAttach` implemented in
the JAR's native code, the agent fails before any Java code runs.
The error is invisible because IBC launches Java with `2>/dev/null`
(see `docker/../IBC/scripts/ibcstart.sh` lines 513-519).

`agent.c` implements `Agent_OnAttach` natively, gets the JVMTI env,
and uses JNI reflection to call
`twslaunch.jsetting.H.a()` (the singleton getter) → `l.u()` (the
`byte[]` getter on the runtime context).

## Container / setup

- Container: `ibkr-tws-prod`, TWS user `tws` uid 1000
- `-Xmx2048m`, G1 GC, Zulu OpenJDK 21
- Host bind-mount: `~/src/ibkr/logs/` → `/home/tws/jts/logs/`
- Encrypted logs (untouched by the agent): on the `tws-data` named
  volume at `/home/tws/jts/oafdloimfccaidpfefaiepmggncpjjnikeekcofk/`

## Files

```
scripts/decrypt/
├── README.md             — entry point for the next session
├── decrypt.sh            — end-to-end: auto-pick key + decrypt
├── decrypt.py            — pure-Python AES-CBC + HMAC + raw-deflate
├── agent.c               — JVMTI agent (built into the image)
├── find-key.sh           — print the current key
└── copy_active_log.sh    — pull the most recent .ibgzenc out
```

## What still needs investigation (later)

1. **Why the heap dump doesn't contain the key.** Even though
   `e.t` references a `byte[]` of length 16, G1 may compact or
   relocate the array. A proper DUMP-format parser would confirm.
2. **Whether the key is also held in native memory** (e.g., in JNI
   CipherSpi state). This could explain why a heap dump doesn't
   show it.
3. **Why stderr=/dev/null in the first place.** IBC's launch
   silently discards JVM errors. A config flag to capture them
   would make future debugging far easier.