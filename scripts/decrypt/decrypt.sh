#!/usr/bin/env bash
# decrypt.sh — Decrypt a TWS .ibgzenc log by picking the right key
# from the persistent keys archive.
#
# The agent running inside TWS writes one key file per extraction to
# /home/tws/jts/logs/keys/key-<unix-ts>.hex, and a `current` symlink
# to the latest one. decrypt.py picks the right key for the log by
# matching log mtime against key timestamps.
#
# Usage:
#   ./decrypt.sh [PATH] [-o OUT] [-k HEX_KEY]
#   PATH defaults to /tmp/active.ibgzenc
#   -k HEX_KEY  Skip auto-pick (use a specific key)
#
# Output: <PATH>.log (or as given by -o).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT=""
KEY=""
POSITIONAL=()

# Try a few sensible defaults for the keys dir. The first one that
# exists wins. We try the container-side path first (in case the
# script is being run inside the container via `docker exec`), then
# the host-side path (in case it's bind-mounted), then the local
# /tmp fallback.
default_keys_dir() {
    for d in \
        /home/tws/jts/logs/keys \
        "$HOME/src/ibkr/logs/keys" \
        /tmp; do
        if [ -d "$d" ]; then
            echo "$d"
            return
        fi
    done
    echo "/home/tws/jts/logs/keys"  # fall back; will error out cleanly
}

KEYS_DIR="${KEYS_DIR:-$(default_keys_dir)}"

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)  OUT="$2"; shift 2;;
        -k|--key)     KEY="$2"; shift 2;;
        --keys-dir)   KEYS_DIR="$2"; shift 2;;
        -h|--help)    grep '^# ' "$0" | sed 's/^# //'; exit 0;;
        -*)           echo "unknown flag: $1" >&2; exit 1;;
        *)            POSITIONAL+=("$1"); shift;;
    esac
done

LOG_PATH="${POSITIONAL[0]:-/tmp/active.ibgzenc}"
[ -f "$LOG_PATH" ] || { echo "error: $LOG_PATH not found" >&2; exit 1; }

OUT="${OUT:-${LOG_PATH%.ibgzenc}.log}"

# Run python with pycryptodome available. nix-shell -p is the standard
# way in this repo; if pycryptodome is already importable, fall back
# to plain python3.
if python3 -c 'from Crypto.Cipher import AES' 2>/dev/null; then
    python3 "$SCRIPT_DIR/decrypt.py" "$LOG_PATH" -o "$OUT" \
        ${KEY:+-k "$KEY"} --keys-dir "$KEYS_DIR"
else
    nix-shell -p python3Packages.pycryptodome --run \
        "python3 '$SCRIPT_DIR/decrypt.py' '$LOG_PATH' -o '$OUT' \
            ${KEY:+-k '$KEY'} --keys-dir '$KEYS_DIR'"
fi
echo "wrote $OUT"