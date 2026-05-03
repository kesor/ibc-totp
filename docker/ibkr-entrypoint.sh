#!/usr/bin/env bash

export DISPLAY="${DISPLAY:-:0}"
export TWS_CREDS_FILE="/run/secrets/tws"
# Xvfb screen geometry, in WIDTHxHEIGHT form (e.g. 1280x800).
# Override at `docker compose up` time:
#     VNC_RESOLUTION=1280x800 docker compose up -d
# Colour depth is fixed at 24 bits internally; nobody cares.
export VNC_RESOLUTION="${VNC_RESOLUTION:-1920x1080}"

ts=$(date -Iminutes|sed -e's/+.*$//g;s/[:-]//g')

cd "${HOME}" || exit 1

# Ensure jts directory exists and is owned by tws user
mkdir -p "${HOME}/jts"

if [ ! -f "${TWS_CREDS_FILE}" ]; then
    echo "Failed to find TWS credentials in '${TWS_CREDS_FILE}'"
    exit 1
fi

# Clean up stale X lock files
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

nohup Xvfb "${DISPLAY}" -br -screen 0 "${VNC_RESOLUTION}x24" 2>"xvfb-err-${ts}.log" >"xvfb-out-${ts}.log" &
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
