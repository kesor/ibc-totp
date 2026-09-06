#!/usr/bin/env bash
# runtime-env.sh — Shared environment for every process the entrypoint
# launches (Xvfb, dbus, IBC/TWS, JxBrowser children). Sourced by
# ibkr-entrypoint.sh; not executed on its own.
#
# LD_LIBRARY_PATH / D-Bus / gsettings live here so all children inherit.
# JVM -D flags that IBC may not preserve via JAVA_TOOL_OPTIONS are set
# again in java-wrapper.sh at the actual `java` exec.

# --- OpenJFX native libs -------------------------------------------------
# openjfx-modular-sdk-25 ships its Java module classes on the classpath
# (IBC already wires those via -cp /nix/store/.../modules/javafx.web:...).
# The native shared objects (libglass.so, libprism_*.so, libjfxmedia.so,
# libjfxwebkit.so, libglassgtk3.so) are NOT in /root/.nix-profile/lib
# and must be discoverable at runtime.
#
# Two sources of these libs exist:
#   1. /nix/store/...-openjfx-modular-sdk/modules_libs/{javafx.graphics,
#      javafx.media,java fx.web}/   — from `openjfx25` nix-env package
#   2. /home/tws/ibkr-tws/${TWS_BUILD}/jre/lib/   — bundled with TWS itself
#
# IMPORTANT: the two sources must NOT be mixed. Different nixpkgs revisions
# of openjfx25 ship different builds of libglass.so/libprism_*.so than the
# JRE TWS bundles, and they are NOT ABI-compatible — putting both on the
# path causes a hard JVM SIGSEGV during JavaFX init:
#
#   SIGSEGV (0xb) at pc=... libjvm.so+0xabecf9  jni_NewObject+0xf9
#
# (This bit us in 2026-09: the modular SDK dropped javafx.web from
# modules_libs/ so libjfxwebkit.so wasn't on the path at all → every
# JavaFX WebView (IBOT dialog = feature.bot.webui, GSTAT bulletins =
# twslaunch.gstat.j) crashed with "UnsatisfiedLinkError: no jfxwebkit".
# Adding the TWS JRE lib dir to fix that brought the second source in,
# and TWS then died with SIGSEGV during startup.)
#
# Resolution: use ONLY the TWS-bundled JRE lib dir. It contains the full
# set of native libs (including libjfxwebkit.so), it is ABI-matched to
# the Java modules TWS itself loads, and it is guaranteed to exist because
# the Dockerfile installs TWS before this script ever runs.
#
# The openjfx25 nix-env entry stays in the Dockerfile only because IBC's
# classpath assembly pulls /nix/store/.../modules/javafx.{base,controls,
# fxml,graphics,media,swing,web,jdk.jsobject,...} for the Java classes.
OPENJFX_LIBRARY_PATH="/home/tws/ibkr-tws/${TWS_BUILD:-stable}/jre/lib"
export OPENJFX_LIBRARY_PATH

# --- Base native search path --------------------------------------------
_ld="/root/.nix-profile/lib"
if [ -n "${OPENJFX_LIBRARY_PATH}" ]; then
    _ld="${OPENJFX_LIBRARY_PATH}:${_ld}"
fi
# JxBrowser tree + ungoogled RUNPATH (setup-jxbrowser.sh)
if [ -f /home/tws/.tws-tools/jxbrowser-ld-path ]; then
    _jxb="$(tr -d '\n' < /home/tws/.tws-tools/jxbrowser-ld-path)"
    _ld="${_jxb}:${_ld}"
    unset _jxb
fi
export LD_LIBRARY_PATH="${_ld}${LD_LIBRARY_PATH:+:}${LD_LIBRARY_PATH}"
unset _ld

# Also publish via JAVA_TOOL_OPTIONS for any non-wrapper java launches.
# java-wrapper.sh re-applies the same -D flags on the argv (more reliable
# under IBC/install4j, which has been observed to clear JAVA_TOOL_OPTIONS).
_java_opts=""
if [ -n "${OPENJFX_LIBRARY_PATH}" ]; then
    _java_opts="-Djavafx.library.path=${OPENJFX_LIBRARY_PATH}"
fi
if [ -d /home/tws/.jxbrowser ]; then
    _java_opts="${_java_opts:+${_java_opts} }-Djxbrowser.chromium.dir=/home/tws/.jxbrowser"
fi
if [ -n "${_java_opts}" ]; then
    export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+${JAVA_TOOL_OPTIONS} }${_java_opts}"
fi
unset _java_opts

# --- GSettings schemas (quiets Chromium GLib-GIO-CRITICAL noise) --------
_schema_dirs=""
for _s in /root/.nix-profile/share/gsettings-schemas/*/glib-2.0/schemas \
          /nix/store/*-gsettings-desktop-schemas-*/share/gsettings-schemas/*/glib-2.0/schemas \
          /nix/store/*-gtk+3-*/share/gsettings-schemas/*/glib-2.0/schemas; do
    if [ -d "${_s}" ]; then
        _schema_dirs="${_schema_dirs}${_schema_dirs:+:}${_s}"
    fi
done
if [ -n "${_schema_dirs}" ]; then
    export GSETTINGS_SCHEMA_DIR="${_schema_dirs}${GSETTINGS_SCHEMA_DIR:+:}${GSETTINGS_SCHEMA_DIR}"
    export XDG_DATA_DIRS="/root/.nix-profile/share${XDG_DATA_DIRS:+:}${XDG_DATA_DIRS}"
fi
unset _s _schema_dirs
