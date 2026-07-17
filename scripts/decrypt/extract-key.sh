#!/usr/bin/env bash
# extract-key.sh — Attach the JVMTI agent to the running TWS JVM
# and write the extracted AES key to /tmp/tws-log-key.hex and to
# ~/src/ibkr/jts/logs/keys/.
#
# Usage:
#   ./extract-key.sh           # use defaults
#   CONTAINER=foo ./extract-key.sh
#
# Output:
#   /tmp/tws-log-key.hex       — 32-char hex (16-byte AES key)
#   ~/src/ibkr/jts/logs/keys/key-<ts>.hex  (also written via the bind-mount)
#
# The agent binary must be present inside the container at
# /home/tws/.tws-tools/libagent.so. If it's missing, this script
# can build it from scripts/decrypt/agent.c (requires gcc + JDK
# headers on the host) and copy it in.
#
# IMPORTANT: the JVM agent load at TWS STARTUP via -agentpath: crashes
# the JVM (SIGSEGV during Threads::create_vm). This script attaches
# the agent AFTER TWS is running, which works. That's also why the
# image's java-wrapper.sh defaults to IBC_DISABLE_AGENT=1.

set -euo pipefail

CONTAINER="${CONTAINER:-ibkr-tws-prod}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SRC="$SCRIPT_DIR/agent.c"
AGENT_SO_IN_CONTAINER="/tmp/libagent.so"
KEYS_DIR="${KEYS_DIR:-$HOME/src/ibkr/jts/logs/keys}"

JAVA_PID=$(docker exec "$CONTAINER" /root/.nix-profile/bin/jcmd 2>/dev/null \
  | awk '/ibcalpha.ibc.IbcTws/{match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); exit}')

if [ -z "$JAVA_PID" ]; then
    echo "error: TWS Java not found in container $CONTAINER" >&2
    exit 1
fi
echo "TWS Java PID: $JAVA_PID" >&2

# Build the agent if needed and copy into the container.
if ! docker exec "$CONTAINER" test -f "$AGENT_SO_IN_CONTAINER"; then
    if [ ! -f "$AGENT_SRC" ]; then
        echo "error: agent source not found at $AGENT_SRC" >&2
        exit 1
    fi
    echo "Building agent locally..." >&2
    JAVAH=$(find /nix/store -maxdepth 1 -name "*-openjdk-21*" -type d 2>/dev/null \
        | head -1)
    if [ -z "$JAVAH" ]; then
        echo "error: OpenJDK 21 not found in /nix/store; install via nix-shell -p openjdk" >&2
        exit 1
    fi
    JAVAH_INC="$JAVAH/lib/openjdk/include"
    if [ ! -d "$JAVAH_INC" ]; then
        JAVAH_INC="$JAVAH/include"
    fi
    if [ ! -f "$JAVAH_INC/jvmti.h" ]; then
        echo "error: jvmti.h not found under $JAVAH_INC" >&2
        exit 1
    fi
    gcc -O2 -fPIC -shared -o /tmp/libagent.so "$AGENT_SRC" \
        -I"$JAVAH_INC" -I"$JAVAH_INC/linux"
fi
docker cp /tmp/libagent.so "$CONTAINER:$AGENT_SO_IN_CONTAINER" 2>/dev/null \
    || docker cp "$(find /tmp -maxdepth 1 -name 'libagent.so' | head -1)" \
       "$CONTAINER:$AGENT_SO_IN_CONTAINER"

# Don't clear /tmp/agent-trace.log — it would clobber the file the
# running agent already has open. Just note that we ran.
docker exec -u tws "$CONTAINER" sh -c \
    'echo "[extract-key.sh run at $(date -Iseconds)]" >> /tmp/agent-trace.log'

# Attach. This is the path that works (post-startup attach).
echo "Attaching agent to PID $JAVA_PID..." >&2
RESULT=$(docker exec -u tws "$CONTAINER" /root/.nix-profile/bin/jcmd "$JAVA_PID" \
    JVMTI.agent_load "$AGENT_SO_IN_CONTAINER" 2>&1)
echo "$RESULT" >&2

# Pull the trace for debugging.
docker cp "$CONTAINER:/tmp/agent-trace.log" /tmp/agent-trace.log >/dev/null 2>&1 || true
echo "Agent trace:" >&2
sed 's/^/  /' /tmp/agent-trace.log >&2 2>/dev/null || true

# Pull the key from the container and copy to the host bind-mount.
# The agent writes to /home/tws/jts/logs/keys/ in the container, which
# is bind-mounted to ~/src/ibkr/jts/logs/keys/ on the host.
echo "Agent trace (from inside container):" >&2
docker exec "$CONTAINER" sh -c 'cat /tmp/agent-trace.log 2>/dev/null | tail -10' >&2

# Read the key file written by the agent.
LATEST_KEY=$(docker exec "$CONTAINER" sh -c \
    "ls -1t /home/tws/jts/logs/keys/key-*.hex 2>/dev/null | head -1")
if [ -z "$LATEST_KEY" ]; then
    echo "error: agent didn't write a key file" >&2
    exit 1
fi
echo "Key file (container): $LATEST_KEY" >&2

KEY=$(docker exec "$CONTAINER" cat "$LATEST_KEY" | tr -d '\n')
echo "$KEY" > /tmp/tws-log-key.hex
echo "Key: $KEY" >&2
echo "Written to /tmp/tws-log-key.hex" >&2
echo "Also available on host at ~/src/ibkr/jts/logs/keys/$(basename "$LATEST_KEY")" >&2