#!/usr/bin/env bash
# runtime-env.sh — Shared environment for every process the entrypoint
# launches (Xvfb, dbus, IBC/TWS, JxBrowser children). Sourced by
# ibkr-entrypoint.sh; not executed on its own.
#
# LD_LIBRARY_PATH / D-Bus / gsettings live here so all children inherit.
# JVM -D flags that IBC may not preserve via JAVA_TOOL_OPTIONS are set
# again in java-wrapper.sh at the actual `java` exec.

# --- OpenJFX native libs -------------------------------------------------
# openjfx21 ships modules on the classpath (IBC already wires those)
# but the glass/prism shared objects live under modules_libs/ and are
# NOT on the default library path.
_openjfx_root=""
for _d in /nix/store/*-openjfx-modular-sdk-*; do
    if [ -d "${_d}/modules_libs/javafx.graphics" ]; then
        _openjfx_root="${_d}"
        break
    fi
done
OPENJFX_LIBRARY_PATH=""
if [ -n "${_openjfx_root}" ]; then
    OPENJFX_LIBRARY_PATH="${_openjfx_root}/modules_libs/javafx.graphics"
    if [ -d "${_openjfx_root}/modules_libs/javafx.media" ]; then
        OPENJFX_LIBRARY_PATH="${OPENJFX_LIBRARY_PATH}:${_openjfx_root}/modules_libs/javafx.media"
    fi
fi
export OPENJFX_LIBRARY_PATH
unset _d _openjfx_root

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
