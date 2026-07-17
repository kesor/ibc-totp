#!/usr/bin/env bash
# IBC launches us with absolute path checked as `${java_path}/java`.
# Forward to whatever java is on PATH (the zulu21 we installed).
#
# Shared runtime env (OpenJFX natives on LD_LIBRARY_PATH, D-Bus address,
# gsettings) is set by ibkr-entrypoint.sh via runtime-env.sh and
# inherited here. This wrapper only adds JVM argv that must survive
# IBC/install4j (which has been observed to drop JAVA_TOOL_OPTIONS).

# Safety net: if entrypoint didn't source runtime-env (manual debug
# launches), still put profile libs + OpenJFX natives on the path.
if [ -z "${LD_LIBRARY_PATH:-}" ] || [[ ":${LD_LIBRARY_PATH}:" != *":/root/.nix-profile/lib:"* ]]; then
    export LD_LIBRARY_PATH="/root/.nix-profile/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
if [ -z "${OPENJFX_LIBRARY_PATH:-}" ]; then
    for _d in /nix/store/*-openjfx-modular-sdk-*; do
        if [ -d "${_d}/modules_libs/javafx.graphics" ]; then
            OPENJFX_LIBRARY_PATH="${_d}/modules_libs/javafx.graphics"
            if [ -d "${_d}/modules_libs/javafx.media" ]; then
                OPENJFX_LIBRARY_PATH="${OPENJFX_LIBRARY_PATH}:${_d}/modules_libs/javafx.media"
            fi
            export OPENJFX_LIBRARY_PATH
            export LD_LIBRARY_PATH="${OPENJFX_LIBRARY_PATH}:${LD_LIBRARY_PATH}"
            break
        fi
    done
    unset _d
fi
if [ -f /home/tws/.tws-tools/jxbrowser-ld-path ]; then
    _jxb="$(tr -d '\n' < /home/tws/.tws-tools/jxbrowser-ld-path)"
    case ":${LD_LIBRARY_PATH}:" in
        *":${_jxb}:"*) ;;
        *) export LD_LIBRARY_PATH="${_jxb}:${LD_LIBRARY_PATH}" ;;
    esac
    unset _jxb
fi

# OpenJFX: tell the runtime where libglass/libprism live.
if [ -n "${OPENJFX_LIBRARY_PATH:-}" ]; then
    set -- -Djavafx.library.path="${OPENJFX_LIBRARY_PATH}" "$@"
fi

# JxBrowser: use pre-extracted Chromium (setup-jxbrowser.sh).
if [ -d /home/tws/.jxbrowser ]; then
    set -- -Djxbrowser.chromium.dir=/home/tws/.jxbrowser "$@"
fi

# Do NOT load the JVMTI key-extraction agent via -agentpath here.
# Zulu OpenJDK 21 + TWS 10.48 + -agentpath: SIGSEGVs during
# Threads::create_vm. Key extraction is handled post-start by
# docker/attach-agent.sh (jcmd JVMTI.agent_load).
AGENT="/home/tws/.tws-tools/libagent.so"
if [ "${IBC_DISABLE_AGENT:-1}" != "1" ] && [ -f "$AGENT" ]; then
    set -- -agentpath:"$AGENT" "$@"
fi

exec /root/.nix-profile/bin/java "$@"
