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

# JxBrowser's private Chromium is a normal glibc ELF tree (see
# docker/setup-jxbrowser.sh). It needs:
#   - /lib64/ld-linux-x86-64.so.2  (installed by setup-jxbrowser)
#   - the same system libs ungoogled-chromium already uses, via
#     LD_LIBRARY_PATH (we cannot patchelf: JxBrowser verifies file
#     sizes against chromium-linux64.info)
#   - -Djxbrowser.chromium.dir pointing at the pre-extracted tree
#     so it never tries the jar's FHS 7zr-linux64 unpacker.
if [ -f /home/tws/.tws-tools/jxbrowser-ld-path ]; then
    _jxb_ld="$(tr -d '\n' < /home/tws/.tws-tools/jxbrowser-ld-path)"
    export LD_LIBRARY_PATH="${_jxb_ld}${LD_LIBRARY_PATH:+:}${LD_LIBRARY_PATH}"
    unset _jxb_ld
fi
if [ -d /home/tws/.jxbrowser ]; then
    set -- -Djxbrowser.chromium.dir=/home/tws/.jxbrowser "$@"
fi

# Do NOT load the JVMTI key-extraction agent via -agentpath here.
# Zulu OpenJDK 21 + TWS 10.48 + -agentpath: SIGSEGVs during
# Threads::create_vm. Key extraction is handled post-start by
# docker/attach-agent.sh (jcmd JVMTI.agent_load), started from
# ibkr-entrypoint.sh. See scripts/decrypt/agent.c.
#
# Optional escape hatch for experiments only:
AGENT="/home/tws/.tws-tools/libagent.so"
if [ "${IBC_DISABLE_AGENT:-1}" != "1" ] && [ -f "$AGENT" ]; then
    set -- -agentpath:"$AGENT" "$@"
fi

exec /root/.nix-profile/bin/java "$@"
