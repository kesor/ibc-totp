#!/usr/bin/env bash
# setup-jxbrowser.sh — Pre-extract JxBrowser's private Chromium so
# TradingView / advanced charts work inside this Nix-based container.
#
# Why we cannot just symlink ungoogled-chromium into place:
#   JxBrowser ships a private Chromium build plus IPC glue
#   (libtoolkit.so, libipc.so, libawt_toolkit.so). Stock Chromium has
#   none of those; swapping the binary breaks Engine.newInstance().
#
# Why we do NOT patchelf the binaries:
#   JxBrowser verifies each extracted file's size against
#   chromium-linux64.info inside jxbrowser-*.jar. patchelf changes
#   file sizes (RUNPATH expansion), verification fails, and the
#   engine aborts with ChromiumProcessStartupFailureException.
#
# What we do instead:
#   1. Install a /lib64/ld-linux-x86-64.so.2 symlink pointing at the
#      nix glibc dynamic linker (the jar's ELFs hardcode that path).
#   2. Extract chromium-linux64.7z from jxbrowser-linux64-*.jar with
#      nix's 7zr (the jar's own 7zr-linux64 is an FHS binary that
#      also needs the linker symlink — once the symlink exists it
#      works, but nix 7zr is simpler and already trusted).
#   3. Write a LD_LIBRARY_PATH fragment reused from the working
#      ungoogled-chromium binary's RUNPATH (same system libs).
#   4. Leave file sizes byte-identical to the jar so verification
#      passes. java-wrapper.sh sources the LD path and sets
#      -Djxbrowser.chromium.dir.

set -euo pipefail

log() { echo "[setup-jxbrowser] $*" >&2; }

JXB_VER="${JXB_VER:-8.9.4}"
TWS_BUILD="${TWS_BUILD:-stable}"
JAR="${JXBROWSER_JAR:-/home/tws/ibkr-tws/${TWS_BUILD}/jars/jxbrowser-linux64-${JXB_VER}.jar}"
DEST_HOME="${JXBROWSER_DIR:-/home/tws/.jxbrowser/${JXB_VER}}"
DEST_TMP="/tmp/JxBrowser/${JXB_VER}"
MARKER="${DEST_HOME}/.nix-ready"
LD_PATH_FILE="${LD_PATH_FILE:-/home/tws/.tws-tools/jxbrowser-ld-path}"
PATH="/root/.nix-profile/bin:${PATH}"

if [ ! -f "$JAR" ]; then
    log "jar not found: $JAR (skipping)"
    exit 0
fi

# --- 1. Dynamic linker at the FHS path every glibc ELF expects --------
install_dynamic_linker() {
    local glibc_ld
    if [ -e /lib64/ld-linux-x86-64.so.2 ]; then
        log "linker already present: /lib64/ld-linux-x86-64.so.2"
        return 0
    fi
    glibc_ld="$(ls /nix/store/*glibc-*/lib/ld-linux-x86-64.so.2 2>/dev/null | head -1 || true)"
    if [ -z "$glibc_ld" ]; then
        log "error: nix glibc dynamic linker not found under /nix/store"
        exit 1
    fi
    if ! mkdir -p /lib64 /lib 2>/dev/null; then
        log "error: cannot create /lib64 (need root once at image build)"
        exit 1
    fi
    if ! ln -sfn "$glibc_ld" /lib64/ld-linux-x86-64.so.2 2>/dev/null \
        || ! ln -sfn "$glibc_ld" /lib/ld-linux-x86-64.so.2 2>/dev/null; then
        log "error: cannot write linker symlink (need root once at image build)"
        exit 1
    fi
    log "linker: /lib64/ld-linux-x86-64.so.2 -> $glibc_ld"
}

# --- 2. LD_LIBRARY_PATH borrowed from working ungoogled-chromium ------
write_ld_path() {
    local uc_wrap real rpath
    uc_wrap="$(readlink -f /root/.nix-profile/bin/chromium 2>/dev/null || true)"
    if [ -z "$uc_wrap" ] || [ ! -f "$uc_wrap" ]; then
        log "error: ungoogled-chromium wrapper not found in profile"
        exit 1
    fi
    real="$(grep -oE '/nix/store/[^" ]+/libexec/chromium/chromium' "$uc_wrap" | head -1 || true)"
    if [ -z "$real" ] || [ ! -f "$real" ]; then
        log "error: could not resolve ungoogled-chromium real binary from $uc_wrap"
        exit 1
    fi
    if ! command -v patchelf >/dev/null 2>&1; then
        log "error: patchelf not on PATH (needed only to read ungoogled RUNPATH)"
        exit 1
    fi
    rpath="$(patchelf --print-rpath "$real")"
    mkdir -p "$(dirname "$LD_PATH_FILE")"
    # DEST first so libtoolkit/libipc resolve next to the binary.
    printf '%s\n' "${DEST_HOME}:${rpath}" > "$LD_PATH_FILE"
    log "wrote $LD_PATH_FILE"
}

install_dynamic_linker
write_ld_path

# --- 3. Extract chromium if missing / incomplete ----------------------
need_extract=0
if [ ! -f "$MARKER" ] || [ ! -x "${DEST_HOME}/chromium" ] || [ ! -f "${DEST_HOME}/libtoolkit.so" ]; then
    need_extract=1
fi

if [ "$need_extract" -eq 0 ]; then
    log "chromium already present at ${DEST_HOME}"
else
    if ! command -v 7zr >/dev/null 2>&1; then
        log "error: 7zr not on PATH (install nixpkgs.p7zip)"
        exit 1
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        log "error: unzip not on PATH"
        exit 1
    fi

    log "extracting ${JAR} → ${DEST_HOME}"
    workdir="$(mktemp -d)"
    cleanup() { rm -rf "$workdir"; }
    trap cleanup EXIT

    mkdir -p "$DEST_HOME"
    unzip -o -q "$JAR" "${JXB_VER}/chromium-linux64.7z" -d "$workdir"
    # Extract into DEST_HOME itself (archive has files at top level).
    7zr x -y -o"${DEST_HOME}" "${workdir}/${JXB_VER}/chromium-linux64.7z" >/dev/null
    chmod a+x "${DEST_HOME}/chromium" "${DEST_HOME}/chrome_crashpad_handler" 2>/dev/null || true

    # Leave a nix-7zr wrapper named 7zr-linux64 so a re-extract path
    # also works. Use /bin/sh (always present) — /bin/bash is not.
    cat > "${DEST_HOME}/7zr-linux64" <<'EOF'
#!/bin/sh
exec /root/.nix-profile/bin/7zr "$@"
EOF
    chmod a+x "${DEST_HOME}/7zr-linux64"

    date -Iseconds > "$MARKER"
    trap - EXIT
    cleanup 2>/dev/null || true
    log "extracted $(stat -c%s "${DEST_HOME}/chromium" 2>/dev/null || echo '?') byte chromium binary"
fi

# --- 4. Mirror under /tmp (JxBrowser default when property unset) -----
mkdir -p /tmp/JxBrowser
if [ ! -e "${DEST_TMP}/chromium" ] || [ "${DEST_HOME}/chromium" -nt "${DEST_TMP}/chromium" ]; then
    rm -rf "$DEST_TMP"
    cp -a "$DEST_HOME" "$DEST_TMP"
    log "published ${DEST_TMP}"
fi

log "ready: ${DEST_HOME}"
