#!/usr/bin/env bash

export DISPLAY="${DISPLAY:-:0}"
export TWS_CREDS_FILE="/run/secrets/tws"

# Disable core dumps. Chromium (and JxBrowser's bundled chromium) may
# SIGABRT during TWS startup probes inside this container because the
# SUID sandbox helper is locked down by the read-only Nix store; those
# aborts are harmless but each one drops a 20-30 MB core file into
# $HOME, which is on the persistent `tws-data` volume.
#
# `ulimit -c 0` blocks per-process dumps. Also write to /proc so any
# child process (chromium is fork+exec'd) inherits the disabled state.
ulimit -c 0
echo 0 > /proc/sys/kernel/core_pattern 2>/dev/null || true

ts=$(date -Iminutes|sed -e's/+.*$//g;s[:-]//g')

cd "${HOME}" || exit 1

# Ensure jts directory exists and is owned by tws user
mkdir -p "${HOME}/jts"

# Ensure the decryption-keys archive subdirs exist. The host bind-mount
# at $HOME/jts/logs may be empty on first `docker compose up`; we create
# `keys/` and `decrypted/` here so the JVMTI agent has somewhere to
# write keys. Files written by the in-container `tws` user (uid 1000)
# will appear in the host dir owned by uid 1000.
mkdir -p "${HOME}/jts/logs/keys" "${HOME}/jts/logs/decrypted"

# Tidy up after any pre-restart crashes:
#   - core.* files dropped by chromium/JVM aborts (these lived on the
#     ephemeral container layer, but `core` files in $HOME will still
#     show up in the persistent `jts/` if anything weird happens; clean
#     just to be safe).
#   - We do NOT remove ~/chromium/ — JxBrowser rebuilds it lazily and
#     nuking it on every restart wipes the device fingerprint IBKR's
#     SSO auth flow uses. It's on the container's ephemeral layer
#     (only jts/ is mounted as a persistent volume), so it's fresh on
#     every container boot regardless.
rm -f "${HOME}"/core.* 2>/dev/null || true

if [ ! -f "${TWS_CREDS_FILE}" ]; then
    echo "Failed to find TWS credentials in '${TWS_CREDS_FILE}'"
    exit 1
fi

# Clean up stale X lock files
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

nohup Xvfb "${DISPLAY}" -br -screen 0 2560x1440x24 2>"xvfb-err-${ts}.log" >"xvfb-out-${ts}.log" &
# wait for X server to start
sleep 15
# Allow all X connections
export XAUTHORITY="${HOME}/.Xauthority"
touch "${XAUTHORITY}"

# Start window manager
nohup openbox 2>"openbox-err-${ts}.log" >"openbox-out-${ts}.log" &
# Start panel/taskbar
nohup tint2 2>"tint2-err-${ts}.log" >"tint2-out-${ts}.log" &

nohup x11vnc -nopw -display "${DISPLAY}" -forever 2>"x11-err-${ts}.log" >"x11-out-${ts}.log" &
nohup /ibc-start.sh 2>"ibc-err-${ts}.log" >"ibc-out-${ts}.log" &

sleep infinity
