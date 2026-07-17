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

ts=$(date -Iminutes | sed 's/+.*//; s/[-:]//g')

cd "${HOME}" || exit 1

# Ensure jts directory exists and is owned by tws user
mkdir -p "${HOME}/jts"

# Ensure the decryption-keys archive subdirs exist. The host bind-mount
# at $HOME/jts/logs may be empty on first `docker compose up`; we create
# `keys/` and `decrypted/` here so the JVMTI agent has somewhere to
# write keys. Files written by the in-container `tws` user (uid 1000)
# will appear in the host dir owned by uid 1000.
mkdir -p "${HOME}/jts/logs/keys" "${HOME}/jts/logs/decrypted"

# Ensure JxBrowser Chromium is extracted (and re-published under
# /tmp/JxBrowser after a container recreate wipes /tmp). Built into
# the image by the Dockerfile; cheap no-op when the marker is present.
if [ -x /setup-jxbrowser.sh ]; then
    /setup-jxbrowser.sh || echo "[entrypoint] setup-jxbrowser failed (charts may not work)" >&2
fi

# Shared env for every service we start below (OpenJFX natives,
# LD_LIBRARY_PATH, JAVA_TOOL_OPTIONS, gsettings). Must run after
# setup-jxbrowser so jxbrowser-ld-path exists.
# shellcheck source=/dev/null
. /runtime-env.sh

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

# --- session D-Bus -------------------------------------------------------
# Chromium/JxBrowser and GTK want a session bus. Without it the logs
# fill with "Failed to connect to the bus" / GLib-GIO-CRITICAL noise.
# A private unix socket under /tmp is enough; no system bus needed.
# Unique socket path so a fast docker-restart cannot race a dying daemon
# still bound to a fixed /tmp/dbus-session path.
DBUS_SOCK="/tmp/dbus-session-${ts}"
rm -f "${DBUS_SOCK}"
if command -v dbus-daemon >/dev/null 2>&1; then
    # Prefer the nix-store session.conf via --config-file. Plain
    # `--session` looks for /etc/dbus-1/session.conf; symlinking the
    # nix file there is circular (it <include>s /etc/dbus-1/session.conf).
    _dbus_conf=""
    for _c in /root/.nix-profile/share/dbus-1/session.conf \
              /nix/store/*-dbus-*/share/dbus-1/session.conf; do
        if [ -f "${_c}" ]; then
            _dbus_conf="${_c}"
            break
        fi
    done
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_SOCK}"
    if [ -n "${_dbus_conf}" ] \
        && dbus-daemon --config-file="${_dbus_conf}" \
            --address="${DBUS_SESSION_BUS_ADDRESS}" --fork \
            2>"dbus-err-${ts}.log"; then
        echo "[entrypoint] dbus session at ${DBUS_SESSION_BUS_ADDRESS}" >&2
    else
        echo "[entrypoint] dbus-daemon failed (see dbus-err-${ts}.log)" >&2
        unset DBUS_SESSION_BUS_ADDRESS
    fi
    unset _c _dbus_conf
else
    echo "[entrypoint] dbus-daemon not installed; skipping session bus" >&2
fi

# Clean up stale X lock files
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

# Xvfb with GLX so Chromium/ANGLE can initialize an OpenGL path instead
# of immediately falling back after "GLX is not present". +iglx enables
# indirect GLX (default is off on modern Xorg); +extension GLX makes
# the GLX extension available to clients. Software mesa still backs
# this under Xvfb — we just stop lying about GLX being missing.
nohup Xvfb "${DISPLAY}" -br -screen 0 2560x1440x24 \
    +extension GLX +iglx +extension RANDR +render -noreset \
    2>"xvfb-err-${ts}.log" >"xvfb-out-${ts}.log" &
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

# Keep the JVMTI key-extraction agent attached across TWS restarts, and
# bulk-decrypt any .ibgzenc logs once a key is available. See
# docker/attach-agent.sh — we cannot use -agentpath at JVM startup
# (SIGSEGV); post-start jcmd attach is the path that works.
if [ -x /attach-agent.sh ]; then
    nohup /attach-agent.sh 2>"attach-agent-err-${ts}.log" >"attach-agent-out-${ts}.log" &
fi

sleep infinity
