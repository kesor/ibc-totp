#!/usr/bin/env bash

export DISPLAY="${DISPLAY:-:0}"
export TWS_CREDS_FILE="/run/secrets/tws"

ts=$(date -Iminutes|sed -e's/+.*$//g;s/[:-]//g')

cd "${HOME}" || exit 1

# Ensure jts directory exists and is owned by tws user
mkdir -p "${HOME}/jts"

if [ ! -f "${TWS_CREDS_FILE}" ]; then
    echo "Failed to find TWS credentials in '${TWS_CREDS_FILE}'"
    exit 1
fi

nohup Xvfb "${DISPLAY}" -br -xinerama -screen 0 2560x1440x24 2>"xvfb-err-${ts}.log" >"xvfb-out-${ts}.log" &
# wait for X server to start
sleep 15
# Allow all X connections
export XAUTHORITY="${HOME}/.Xauthority"
touch "${XAUTHORITY}"

nohup x11vnc -nopw -display "${DISPLAY}" -ncache 10 -ncache_cr -forever -speeds lan 2>"x11-err-${ts}.log" >"x11-out-${ts}.log" &
nohup /ibc-start.sh 2>"ibc-err-${ts}.log" >"ibc-out-${ts}.log" &

sleep infinity
