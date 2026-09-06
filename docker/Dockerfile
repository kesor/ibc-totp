FROM nixos/nix:latest

ARG IBC_VERSION=3.23.0
ARG TWS_BUILD=stable

# Install packages (cached layer — changes here invalidate only this RUN)
#
# Use `zulu25` (Azul Zulu 25) — the same JRE vendor TWS itself bundles.
# The current TWS installer ships install4j bootstrap classes compiled
# for Java 25 (class file 69.0), so a 21 JRE no longer runs it.
# Pair with `openjfx25` because TWS's launcher uses `--add-exports` flags
# for `javafx.*` modules that Zulu doesn't ship — a later RUN adds the
# openjfx classpath into IBC.
#
# The base image's `<nixpkgs>` channel points at nixos-unstable.
# Allow unfree for `corefonts` (Microsoft EULA) and `vista-fonts` (also
# Microsoft-distributed). Both ship useful fonts not in any free set.
RUN mkdir -p ~/.config/nixpkgs && \
    printf '{ allowUnfree = true; }\n' > ~/.config/nixpkgs/config.nix && \
    cat ~/.config/nixpkgs/config.nix

RUN nix-env -f '<nixpkgs>' -iA \
      zulu25 \
      openjfx25 \
      # zlib: previously transitively pulled into /root/.nix-profile/lib
      # by another package; recent nixpkgs cleanup dropped that closure
      # and `java` started failing with "error while loading shared
      # libraries: libz.so.1". Install explicitly so /root/.nix-profile/lib
      # always has libz.so.1 and runtime-env.sh's existing path includes it.
      zlib \
      curl unzip \
      xorg-server xauth xvfb-run x11vnc \
      openbox tint2 \
      ungoogled-chromium \
      bash coreutils findutils gnused gnugrep gawk util-linux \
      fontconfig \
      socat \
      noto-fonts \
      noto-fonts-color-emoji \
      corefonts \
      fira-sans \
      googlesans-code \
      roboto \
      ubuntu-sans \
      ubuntu-sans-mono \
      # chromium 149's text shaping pipeline (HarfBuzz) needs ICU.
      icu \
      # gcc (which pulls in binutils) is needed to build the JVMTI
      # key-extraction agent (see scripts/decrypt/agent.c) at image
      # build time. Don't add binutils separately — its wrappers
      # conflict with gcc-wrapper.
      gcc \
      # In-container bulk decryption of .ibgzenc logs (attach-agent.sh
      # → decrypt.sh → decrypt.py).
      python3 \
      python3Packages.pycryptodome \
      # JxBrowser Chromium prep (setup-jxbrowser.sh): extract the
      # private Chromium tree with nix 7zr. The jar's own 7zr-linux64
      # is an FHS binary and cannot exec on Nix without our linker
      # symlink; we use nix 7zr instead and keep file sizes intact.
      p7zip \
      patchelf \
      # Session D-Bus for Chromium/GTK (entrypoint starts dbus-daemon
      # with the nix session.conf via --config-file).
      dbus \
      # Mesa/GLX for Xvfb +iglx (Chromium ANGLE "GLX is not present").
      # (Usually already pulled by gtk/chromium; listed explicitly.)
      mesa \
      # X11 client libraries for AWT/JavaFX glass + XToolkit.
      libX11 libXext libXtst \
      libXi libXrender libXt \
      libXdmcp libXau

ENV PATH="/root/.nix-profile/bin:${PATH}"

# Wire fontconfig to the system where chromium lives. The Nix-installed
# `fontconfig` doesn't ship a top-level /root/.nix-profile/etc/fonts/fonts.conf
# (only per-family conf.d snippets); we write one at /etc/fonts/fonts.conf
# further down in the Dockerfile. Point FONTCONFIG_FILE there.
ENV \
  FONTCONFIG_PATH=/root/.nix-profile/etc/fonts \
  XDG_DATA_DIRS=/root/.nix-profile/share:/usr/share \
  FONTCONFIG_FILE=/etc/fonts/fonts.conf

ENV CHROMIUM_FLAGS="--no-first-run --no-default-browser-check --disable-features=Translate,InfiniteSessionRestore"

# fontconfig also needs the `fc-cache` cache built or chromium will
# time out on each font lookup. Run it now so the first chromium
# startup is fast.
RUN FC_NUM=$(/root/.nix-profile/bin/fc-list 2>&1 | wc -l) && \
    echo "fontconfig indexed ${FC_NUM} fonts (BEFORE fc-cache)" && \
    /root/.nix-profile/bin/fc-cache -f 2>&1 | tail -5 && \
    FC_NUM=$(/root/.nix-profile/bin/fc-list 2>&1 | wc -l) && \
    echo "fontconfig indexed ${FC_NUM} fonts (AFTER fc-cache)"

# Create user manually (nixos/nix has immutable /etc/passwd and /etc/group)
RUN mkdir -p /home/tws && \
  echo "tws:x:1000:1000::/home/tws:/bin/sh" >> /etc/passwd && \
  echo "tws:x:1000:" >> /etc/group && \
  chown -R 1000:1000 /home/tws

USER tws
WORKDIR /home/tws

# Install IBKR TWS.
#
# install4j's bundled launcher calls "$app_java_home/bin/java" — that
# points to the bundled JRE which (a) can't run on NixOS (no
# /lib64/ld-linux-x86-64.so.2) and (b) has a strict version check
# (17.0.16.0.101 only). We patch the launcher to invoke the bare
# `java` command instead, which resolves to the zulu25 in
# /root/.nix-profile/bin/java. Same trick the flake.nix devShell uses.
#
# This sidesteps both the "no dynamic linker" failure and the
# strict-version check in one move.
RUN set -eux; \
    BUILD="${TWS_BUILD}"; \
    mkdir -p "ibkr-tws/${BUILD}"; \
    curl -fsSL \
      "https://download2.interactivebrokers.com/installers/tws/latest-standalone/tws-latest-standalone-linux-x64.sh" \
      -o /tmp/tws-installer.sh; \
    sed -i 's|\$INSTALL4J_JAVA_PREFIX "\$app_java_home/bin/java"|java|g' /tmp/tws-installer.sh; \
    printf '%s\n%s\n%s\n' "/home/tws/ibkr-tws/${BUILD}" "y" "n" \
      | bash /tmp/tws-installer.sh -- -c; \
    rm -f /tmp/tws-installer.sh; \
    test -d "ibkr-tws/${BUILD}" || { echo "TWS install failed"; exit 1; }; \
    # Patch the installed TWS launcher too — the installer produces its own \
    # copy at ${BUILD}/tws with the same JVM-strictness bugs. The installed \
    # launcher uses '$INSTALL4J_JAVA_PREFIX exec "$app_java_home/bin/java"' \
    # (note the optional `exec`); both forms get the same `java` swap. \
    for f in "ibkr-tws/${BUILD}/tws" "ibkr-tws/${BUILD}"/.*.sh; do \
      if [ -f "$f" ] && grep -q '"\$app_java_home/bin/java"' "$f"; then \
        sed -i 's|\$INSTALL4J_JAVA_PREFIX\( exec\)\? "\$app_java_home/bin/java"|java|g' "$f"; \
        echo "Patched launcher: $f"; \
      fi; \
    done; \
    ls -la "ibkr-tws/${BUILD}"

# Install IBC (from local build with TOTP support)
USER root
COPY docker/IBC /home/tws/IBC/
RUN find /home/tws/IBC -name "*.sh" -type f -exec chmod +x {} \; && \
  chown -R tws:tws /home/tws/IBC

# --- Pin Zulu 25 to a known-good patch ---------------------------------
# Zulu 25.34.17 (jdk25.0.3+9) shipped with a libnet.so regression: calling
# java.net.NetworkInterface.getAll() from a re-entrant JNI context crashes
# the JVM with SIGSEGV at jni_NewObject+0xf9. TWS 10.50.1e hits this on
# startup through feature.telemetry.TelemetryRequestStartSession →
# oshi.LinuxNetworkIF.getNetworks(). Pin to 25.34.15 (jdk25.0.3+8), the
# last known-good patch, by overriding zulu25's src to a fixed URL+hash.
# Remove this layer once Azul ships a fix in 25.0.3+10 or later.
RUN mkdir -p /tmp/zulu-pin && cat > /tmp/zulu-pin/pinned.nix <<'EOF'
(import <nixpkgs> {}).zulu25.overrideAttrs (_: {
  src = (import <nixpkgs> {}).fetchurl {
    url = "https://cdn.azul.com/zulu/bin/zulu25.34.15-ca-jdk25.0.3-linux_x64.tar.gz";
    sha256 = "sha256-AUt6sXLiPqFDLhEVI0SLm/Jz0SdcLc1rbNpO6LpuVTI=";
  };
})
EOF
# Build the pinned derivation, then install it into the user profile by
# store path (nix-env -iE doesn't accept a derivation set directly).
RUN _zulu_store=$(nix-build /tmp/zulu-pin/pinned.nix --no-out-link) && \
    nix-env -i "$_zulu_store" && \
    rm -rf /tmp/zulu-pin && \
    echo "--- Pinned Zulu version ---" && \
    /root/.nix-profile/bin/java -version 2>&1 | head -3

ENV TZ="Asia/Jerusalem"
ENV DISPLAY=:0
ENV XDG_CONFIG_HOME=/home/tws
# (FONTCONFIG_FILE is set above to the Nix-installed fontconfig config.
#  Drop the previous `ENV FONTCONFIG_FILE=/etc/fonts/fonts.conf` — that
#  path doesn't exist in this image, while the Nix path does.)

USER root
COPY docker/ibc-config.ini /home/tws/IBC/
COPY docker/ibkr-entrypoint.sh /docker-entrypoint.sh
COPY docker/ibc-start.sh /ibc-start.sh
COPY --chmod=0755 docker/attach-agent.sh /attach-agent.sh
COPY --chmod=0755 docker/setup-jxbrowser.sh /setup-jxbrowser.sh
COPY docker/runtime-env.sh /runtime-env.sh
# /home/tws/java is required by ibcstart.sh when --java-path=/home/tws is set \
# (it does `[[ ! -e "$java_path/java" ]]` and aborts otherwise). The wrapper \
# just exec's the system java; shared env comes from runtime-env.sh. \
COPY --chmod=0755 docker/java-wrapper.sh /home/tws/java

# Build the JVMTI key-extraction agent + install decrypt tools used by
# attach-agent.sh. The agent is attached POST-startup via jcmd (not
# -agentpath — that SIGSEGVs during Threads::create_vm). It polls
# twslaunch.jclient.login.e for the live AES-128 logKey and writes
# /home/tws/jts/logs/keys/key-<ts>.hex. Headers come from zulu25.
COPY scripts/decrypt/agent.c /tmp/agent.c
COPY scripts/decrypt/decrypt.py scripts/decrypt/decrypt.sh /home/tws/.tws-tools/
RUN mkdir -p /home/tws/.tws-tools && \
    gcc -O2 -fPIC -shared -o /home/tws/.tws-tools/libagent.so \
        /tmp/agent.c \
        -I/root/.nix-profile/include -I/root/.nix-profile/include/linux && \
    rm -f /tmp/agent.c && \
    chmod 0755 /home/tws/.tws-tools/decrypt.sh && \
    chmod 0644 /home/tws/.tws-tools/decrypt.py \
               /home/tws/.tws-tools/libagent.so && \
    chown -R root:root /home/tws/.tws-tools && \
    ls -la /home/tws/.tws-tools/

# Pre-extract JxBrowser Chromium + install /lib64 dynamic linker
# (TradingView / advanced charts). Must run as root after the TWS
# install layer that drops jxbrowser-linux64-*.jar. We keep file
# sizes byte-identical to the jar (no patchelf) so JxBrowser's size
# verification passes; java-wrapper.sh supplies LD_LIBRARY_PATH from
# the working ungoogled-chromium RUNPATH. See docker/setup-jxbrowser.sh.
RUN /setup-jxbrowser.sh && \
    chown -R tws:tws /home/tws/.jxbrowser /home/tws/.tws-tools/jxbrowser-ld-path

# Pre-create /home/tws/chromium with the right ownership and perms so a
# fresh chromium-data named volume (which docker creates as root) gets
# the right uid/gid the moment TWS's JxBrowser panel starts.
RUN mkdir -p /home/tws/chromium && \
    mkdir -p /home/tws/jts && \
    chown -R tws:tws /home/tws

# Write a fonts.conf so fontconfig has *sane* defaults. The upstream
# Nix `fontconfig` package ships only per-family conf.d snippets and
# no top-level fonts.conf; without one, fontconfig's built-in fallback
# resolves the generic `sans-serif` request to whichever font sorts
# first in /root/.nix-profile/share/fonts — historically that has
# been an icon font like Font Awesome 7 (which has zero Latin glyphs,
# so every page renders with empty/tofu boxes), and also Google Sans
# Code (a coding display font with ligatures — wrong for body text).
#
# We:
#   1. Reject icon/coding fonts by file glob so they cannot be picked
#      at all.
#   2. Map sans-serif/serif/monospace aliases to a chosen chain
#      anchored on Liberation/DejaVu (always present, broad coverage).
RUN mkdir -p /etc/fonts && \
    printf '<?xml version="1.0"?>\n\
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">\n\
<fontconfig>\n\
  <dir>/root/.nix-profile/share/fonts</dir>\n\
  <cachedir>/root/.cache/fontconfig</cachedir>\n\
  <include ignore_missing="yes">/root/.nix-profile/etc/fonts/conf.d</include>\n\
  <rejectfont><glob>/root/.nix-profile/share/fonts/googlesans-code/*</glob></rejectfont>\n\
  <alias>\n\
    <family>sans-serif</family>\n\
    <accept><family>DejaVu Sans</family></accept>\n\
    <accept><family>Liberation Sans</family></accept>\n\
    <accept><family>Noto Sans</family></accept>\n\
    <default><family>DejaVu Sans</family></default>\n\
  </alias>\n\
  <alias>\n\
    <family>serif</family>\n\
    <accept><family>Liberation Serif</family></accept>\n\
    <accept><family>DejaVu Serif</family></accept>\n\
    <accept><family>Noto Serif</family></accept>\n\
    <default><family>Liberation Serif</family></default>\n\
  </alias>\n\
  <alias>\n\
    <family>monospace</family>\n\
    <accept><family>DejaVu Sans Mono</family></accept>\n\
    <accept><family>Liberation Mono</family></accept>\n\
    <accept><family>Hack</family></accept>\n\
    <default><family>DejaVu Sans Mono</family></default>\n\
  </alias>\n\
</fontconfig>\n' > /etc/fonts/fonts.conf && \
    ls -la /etc/fonts/

USER tws
ENV PATH="/home/tws:${PATH}"

# Make TWS_BUILD available to scripts that read it at runtime.
ENV TWS_BUILD=${TWS_BUILD}

CMD [ "bash", "/docker-entrypoint.sh" ]
