#!/usr/bin/env bash

mkdir -p "${HOME}/jts"
chmod 755 "${HOME}/jts"
export IBC_INI="${HOME}/IBC/config.ini"
export IBC_PATH="${HOME}/IBC"
export TWS_PATH="${HOME}/ibkr-tws"
export TWS_VERSION="1043"
export TWS_SETTINGS_PATH="${HOME}/jts"
# shellcheck source=tws.secrets
. "${TWS_CREDS_FILE}"
find "${IBC_PATH}" -iname "*.sh" -exec chmod +x {} +

# wait, X11 might not yet be available.

while true; do
    sleep 15
    "${IBC_PATH}/scripts/ibcstart.sh" "${TWS_VERSION}" --tws-path="${TWS_PATH}" --tws-settings-path="${TWS_SETTINGS_PATH}" --ibc-path="${IBC_PATH}" --ibc-ini="${IBC_INI}" --mode=live --java-path="/home/tws" --user="${TWS_USERNAME}" --pw="${TWS_PASSWORD}"
done

echo "*** ibc-start.sh script reached its end ***" 2>&1
