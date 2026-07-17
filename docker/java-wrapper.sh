#!/usr/bin/env bash
# IBC launches us with absolute path checked as `${java_path}/java`.
# Forward to whatever java is on PATH (the zulu21 we installed).
#
# Prepend /root/.nix-profile/lib so that the AWT X11 toolkit
# (libawt_xawt.so) can dlopen libX11.so.6, libXext.so.6, etc.
# Without this path the TWS JavaFX subsystem fails to initialize
# ("No toolkit found"), the embedded HTTP bridge on port 20000 never
# starts, and any chart/calendar/feature that depends on it
# (advanced charts, tradingview, ...) hangs at "Loading...".
export LD_LIBRARY_PATH="/root/.nix-profile/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Load the JVMTI key-extraction agent on every JVM startup. The agent
# polls twslaunch.jclient.login.e for the live AES-128 logKey and
# writes timestamped key files under /home/tws/jts/logs/keys/, which
# is bind-mounted from the host so we can decrypt .ibgzenc log files
# later. See scripts/decrypt/agent.c for the full implementation.
# The agent is a no-op if /home/tws/.tws-tools/libagent.so is missing.
AGENT="/home/tws/.tws-tools/libagent.so"
if [ -f "$AGENT" ]; then
    set -- -agentpath:"$AGENT" "$@"
fi

exec /root/.nix-profile/bin/java "$@"
