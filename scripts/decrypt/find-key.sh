#!/usr/bin/env bash
# find-key.sh — Print the current (most recent) AES-128 key from the
# keys archive that the in-container JVMTI agent maintains.
#
# Usage:
#   ./find-key.sh
#   KEY=... ./find-key.sh             # override keys dir
#
# Outputs the 32-char hex string to stdout, plus a one-line label
# pointing at the source file on stderr.

set -euo pipefail

KEYS_DIR="${KEYS_DIR:-/home/tws/jts/logs/keys}"
CURRENT="${KEYS_DIR}/current"

if [ -L "${CURRENT}" ]; then
    target="${KEYS_DIR}/$(readlink "${CURRENT}")"
    if [ -f "${target}" ]; then
        echo "key file: ${target}" >&2
        cat "${target}"
        exit 0
    fi
fi

# Fallback: most-recently-modified key file.
last="$(ls -1t "${KEYS_DIR}"/key-*.hex 2>/dev/null | head -1 || true)"
if [ -n "${last}" ] && [ -f "${last}" ]; then
    echo "key file: ${last} (no current symlink)" >&2
    cat "${last}"
    exit 0
fi

echo "error: no keys found in ${KEYS_DIR}" >&2
exit 1