#!/usr/bin/env bash
# Copy the active encrypted TWS log file from the container to /tmp/active.ibgzenc
# for offline decryption.
#
# Usage: ./copy_active_log.sh
#
# The "active" log is the one being currently written to (mtime within ~24h).
# All *.ibgzenc files for the current TWS session share the same encryption
# key, so any of them can be used as known-plaintext oracle once the key
# is found.

set -euo pipefail

CONTAINER="${CONTAINER:-ibkr-tws-prod}"

# Find the most recently modified .ibgzenc file
ACTIVE=$(docker exec "$CONTAINER" sh -c '
    ls -t /home/tws/jts/*/tws.*.ibgzenc 2>/dev/null | head -1
')

if [ -z "$ACTIVE" ]; then
    echo "error: no .ibgzenc files found" >&2
    exit 1
fi

echo "active log: $ACTIVE" >&2
docker cp "$CONTAINER:$ACTIVE" /tmp/active.ibgzenc
ls -la /tmp/active.ibgzenc
