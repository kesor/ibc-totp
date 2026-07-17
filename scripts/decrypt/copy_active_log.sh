#!/usr/bin/env bash
# Copy the active encrypted TWS log file to /tmp/active.ibgzenc for
# offline decryption.
#
# Usage: ./copy_active_log.sh
#
# With the current bind-mount layout (~/src/ibkr/jts/ → /home/tws/jts/
# inside the container), the encrypted logs are already on the host.
# We just find the most-recent .ibgzenc and copy it to /tmp. Falls back
# to docker cp if the bind-mount isn't set up.
#
# All *.ibgzenc files for the current TWS session share the same
# encryption key, so any of them can be decrypted once the key is
# found.

set -euo pipefail

CONTAINER="${CONTAINER:-ibkr-tws-prod}"
HOST_JTS="${HOST_JTS:-$HOME/src/ibkr/jts}"

if [ -d "$HOST_JTS" ]; then
    # Find the most recently modified .ibgzenc file on the host.
    # Use a glob that handles arbitrary per-user-dir hashes.
    shopt -s nullglob
    candidates=( "$HOST_JTS"/*/tws.*.ibgzenc )
    shopt -u nullglob
    if [ ${#candidates[@]} -eq 0 ]; then
        echo "error: no .ibgzenc files under $HOST_JTS" >&2
        exit 1
    fi
    # newest first
    latest=$(ls -1t "${candidates[@]}" | head -1)
    echo "active log: $latest" >&2
    cp "$latest" /tmp/active.ibgzenc
else
    # Fall back to docker cp (named volume case).
    ACTIVE=$(docker exec "$CONTAINER" sh -c '
        ls -t /home/tws/jts/*/tws.*.ibgzenc 2>/dev/null | head -1
    ')
    if [ -z "$ACTIVE" ]; then
        echo "error: no .ibgzenc files found in container" >&2
        exit 1
    fi
    echo "active log: $ACTIVE (via docker cp)" >&2
    docker cp "$CONTAINER:$ACTIVE" /tmp/active.ibgzenc
fi
ls -la /tmp/active.ibgzenc