#!/usr/bin/env bash
# decrypt.sh — Decrypt TWS .ibgzenc log(s) by picking the right key
# from the persistent keys archive.
#
# The agent running inside TWS writes one key file per extraction to
# /home/tws/jts/logs/keys/key-<unix-ts>.hex, and a `current` symlink
# to the latest one. decrypt.py picks the right key for each log by
# matching log mtime against key timestamps.
#
# Usage:
#   ./decrypt.sh [PATH ...] [-o OUT] [-k HEX_KEY] [--force]
#   ./decrypt.sh --all [--root DIR] [-k HEX_KEY] [--force]
#   ./decrypt.sh                # same as --all with default roots
#
# PATH defaults: if none given, decrypt every *.ibgzenc under the
# default JTS tree (container or host path, whichever exists).
#
# Output: <PATH with .ibgzenc -> .log> next to each input
#         (or as given by -o, single-file only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT=""
KEY=""
KEYS_DIR=""
ALL=0
ROOT=""
FORCE=0
POSITIONAL=()

default_keys_dir() {
    for d in \
        /home/tws/jts/logs/keys \
        "$HOME/src/ibkr/jts/logs/keys" \
        "$HOME/src/ibkr/logs/keys" \
        /tmp; do
        if [ -d "$d" ]; then
            echo "$d"
            return
        fi
    done
    echo "/home/tws/jts/logs/keys"
}

default_jts_root() {
    for d in \
        /home/tws/jts \
        "$HOME/src/ibkr/jts"; do
        if [ -d "$d" ]; then
            echo "$d"
            return
        fi
    done
    echo "/home/tws/jts"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)  OUT="$2"; shift 2;;
        -k|--key)     KEY="$2"; shift 2;;
        --keys-dir)   KEYS_DIR="$2"; shift 2;;
        --all)        ALL=1; shift;;
        --root)       ROOT="$2"; shift 2;;
        -f|--force)   FORCE=1; shift;;
        -h|--help)    grep '^# ' "$0" | sed 's/^# //'; exit 0;;
        -*)           echo "unknown flag: $1" >&2; exit 1;;
        *)            POSITIONAL+=("$1"); shift;;
    esac
done

KEYS_DIR="${KEYS_DIR:-$(default_keys_dir)}"
ROOT="${ROOT:-$(default_jts_root)}"

# No paths and no --all → decrypt everything under the JTS root.
if [ ${#POSITIONAL[@]} -eq 0 ] && [ "$ALL" -eq 0 ]; then
    ALL=1
fi

if [ "$ALL" -eq 1 ] && [ ${#POSITIONAL[@]} -gt 0 ]; then
    echo "error: --all does not take PATH arguments" >&2
    exit 1
fi

if [ -n "$OUT" ] && { [ "$ALL" -eq 1 ] || [ ${#POSITIONAL[@]} -ne 1 ]; }; then
    echo "error: -o/--output requires exactly one PATH" >&2
    exit 1
fi

run_py() {
    local -a py_args=("$@")
    if python3 -c 'from Crypto.Cipher import AES' 2>/dev/null; then
        python3 "$SCRIPT_DIR/decrypt.py" "${py_args[@]}"
    else
        # Host-side fallback when pycryptodome isn't on the default python.
        local quoted=""
        local a
        for a in "${py_args[@]}"; do
            quoted+=" $(printf '%q' "$a")"
        done
        nix-shell -p python3Packages.pycryptodome --run \
            "python3 $(printf '%q' "$SCRIPT_DIR/decrypt.py")$quoted"
    fi
}

args=(--keys-dir "$KEYS_DIR")
[ -n "$KEY" ] && args+=(-k "$KEY")
[ "$FORCE" -eq 1 ] && args+=(--force)

if [ "$ALL" -eq 1 ]; then
    run_py --all --root "$ROOT" "${args[@]}"
else
    [ -n "$OUT" ] && args+=(-o "$OUT")
    run_py "${args[@]}" "${POSITIONAL[@]}"
    if [ ${#POSITIONAL[@]} -eq 1 ]; then
        out_guess="${OUT:-${POSITIONAL[0]%.ibgzenc}.log}"
        echo "wrote $out_guess"
    fi
fi
