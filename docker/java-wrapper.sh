#!/usr/bin/env bash
# IBC launches us with absolute path checked as `${java_path}/java`.
# Forward to whatever java is on PATH (the zulu-ca-jdk-25 we installed).
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
# Safety net: if entrypoint didn't source runtime-env.sh (manual debug
# launches), still point OPENJFX_LIBRARY_PATH at the TWS-bundled JRE lib.
# We deliberately use ONLY the TWS JRE lib dir (no openjfx-modular-sdk
# modules_libs) — see runtime-env.sh for why mixing the two sources
# causes a JVM SIGSEGV during JavaFX init.
if [ -z "${OPENJFX_LIBRARY_PATH:-}" ]; then
    _tws_jre_lib="/home/tws/ibkr-tws/${TWS_BUILD:-stable}/jre/lib"
    if [ -d "${_tws_jre_lib}" ] && [ -f "${_tws_jre_lib}/libjfxwebkit.so" ]; then
        OPENJFX_LIBRARY_PATH="${_tws_jre_lib}"
        export OPENJFX_LIBRARY_PATH
        export LD_LIBRARY_PATH="${OPENJFX_LIBRARY_PATH}:${LD_LIBRARY_PATH}"
    fi
    unset _tws_jre_lib
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

# Network interface enumeration hardening. TWS 10.50.x's telemetry code
# path calls oshi → java.net.NetworkInterface.getAll() during startup;
# Zulu 25.34.17 (jdk25.0.3+9) had a libnet.so SIGSEGV on this code path
# in some Docker network namespaces. The actual fix for that is pinning
# to Zulu 25.34.15 (see the RUN layer in docker/Dockerfile). These two
# flags are harmless belt-and-braces: prefer IPv4 only and exclude
# "partial" (addressless) interfaces from the enumeration result.
set -- \
    -Djava.net.preferIPv4Stack=true \
    -Djdk.net.includePartialNetworks=false \
    "$@"

# JxBrowser: use pre-extracted Chromium (setup-jxbrowser.sh).
if [ -d /home/tws/.jxbrowser ]; then
    set -- -Djxbrowser.chromium.dir=/home/tws/.jxbrowser "$@"
fi

# Java 25 lowered jdk.xml.elementAttributeLimit from 10000 to 200.
# TWS 10.50's saved layout XML (tws.<weekday>.xml, e.g. tws.Thu.xml)
# can have an <UpgradeHistory> element with >200 attributes from years
# of cumulative upgrades. The default then aborts parsing with
# "JAXP00010002: Element ... has more than '200' attributes" and TWS
# loops forever on the splash screen trying to load that file.
# Restore the pre-25 default. Harmless on older JVMs (they ignore
# values >= their default).
set -- -Djdk.xml.elementAttributeLimit=10000 "$@"

# Do NOT load the JVMTI key-extraction agent via -agentpath here.
# Zulu OpenJDK 21 + TWS 10.48 + -agentpath: SIGSEGVs during
# Threads::create_vm. Key extraction is handled post-start by
# docker/attach-agent.sh (jcmd JVMTI.agent_load).
AGENT="/home/tws/.tws-tools/libagent.so"
if [ "${IBC_DISABLE_AGENT:-1}" != "1" ] && [ -f "$AGENT" ]; then
    set -- -agentpath:"$AGENT" "$@"
fi

exec /root/.nix-profile/bin/java "$@"
