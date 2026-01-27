FROM nixos/nix:latest

ARG IBC_VERSION=3.23.0

# Install packages
RUN nix-env -f '<nixpkgs>' -iA \
    openjdk21 \
    javaPackages.openjfx21 \
    curl unzip \
    xorg.xorgserver xorg.xauth xvfb-run x11vnc \
    openbox tint2 \
    bash coreutils findutils gnused gnugrep util-linux

ENV PATH="/root/.nix-profile/bin:${PATH}"

# Create user manually (nixos/nix has immutable /etc/passwd and /etc/group)
RUN mkdir -p /home/tws && \
    echo "tws:x:1000:1000::/home/tws:/bin/sh" >> /etc/passwd && \
    echo "tws:x:1000:" >> /etc/group && \
    chown -R 1000:1000 /home/tws

USER tws
WORKDIR /home/tws

# Install IBKR TWS - patch installer to use system java
RUN mkdir -p ibkr-tws/1043 && \
    curl -sL "https://download2.interactivebrokers.com/installers/tws/latest-standalone/tws-latest-standalone-linux-x64.sh" -o /tmp/tws-installer.sh && \
    sed -i 's|\$INSTALL4J_JAVA_PREFIX "\$app_java_home/bin/java"|java|' /tmp/tws-installer.sh && \
    echo -e "/home/tws/ibkr-tws/1043\ny\nn" | bash /tmp/tws-installer.sh -- -c && \
    rm /tmp/tws-installer.sh

# Install IBC
RUN mkdir -p IBC && cd IBC && \
    curl -sL https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O && \
    unzip IBCLinux-${IBC_VERSION}.zip && \
    rm IBCLinux-${IBC_VERSION}.zip && \
    find . -name "*.sh" -type f -exec sed -i '1s|^#!/bin/bash|#!/usr/bin/env bash|' {} \; && \
    sed -i '309a JAVAFX_SDK=$(find /nix/store -maxdepth 1 -name "*openjfx-modular-sdk*" -type d 2>/dev/null | head -1)\nif [ -n "$JAVAFX_SDK" ] && [ -d "$JAVAFX_SDK/modules" ]; then\n  JAVAFX_CP=$(find "$JAVAFX_SDK/modules" -maxdepth 1 -type d | tr "\\n" ":" | sed "s/:$//")\n  ibc_classpath="${JAVAFX_CP}:${ibc_classpath}"\nfi' scripts/ibcstart.sh

ENV TZ="Asia/Jerusalem"
ENV DISPLAY=:0
ENV XDG_CONFIG_HOME=/home/tws
ENV FONTCONFIG_FILE=/etc/fonts/fonts.conf

USER root
COPY ibc-config.ini /home/tws/IBC/
COPY ibkr-entrypoint.sh /docker-entrypoint.sh
COPY ibc-start.sh /ibc-start.sh
COPY java-wrapper.sh /home/tws/java
RUN chmod +x /home/tws/java && chown tws:tws /home/tws/java

USER tws
ENV PATH="/home/tws:${PATH}"

CMD [ "bash", "/docker-entrypoint.sh" ]
