#!/usr/bin/env bash
# attach-agent.sh — In-container watchdog that keeps the JVMTI key agent
# attached to TWS and decrypts any .ibgzenc logs it can.
#
# Why this exists:
#   Loading the agent via -agentpath at JVM start crashes TWS (SIGSEGV
#   during Threads::create_vm). Attaching AFTER the JVM is up with
#   `jcmd JVMTI.agent_load` works. IBC also restarts TWS on its own,
#   so we need to re-attach whenever the Java PID changes.
#
# Started from ibkr-entrypoint.sh. Safe to run as the `tws` user.
#
# Env overrides:
#   AGENT_SO          path to libagent.so
#   ATTACH_DELAY_SEC  seconds to wait after a new PID before attach
#                     (let the JVM finish creating threads / auth)
#   POLL_SEC          how often to look for PID changes / re-decrypt
#   JTS_ROOT          where to search for .ibgzenc files
#   DECRYPT_SCRIPT    path to decrypt.sh

set -u

AGENT_SO="${AGENT_SO:-/home/tws/.tws-tools/libagent.so}"
ATTACH_DELAY_SEC="${ATTACH_DELAY_SEC:-30}"
POLL_SEC="${POLL_SEC:-60}"
JTS_ROOT="${JTS_ROOT:-/home/tws/jts}"
DECRYPT_SCRIPT="${DECRYPT_SCRIPT:-/home/tws/.tws-tools/decrypt.sh}"
JCMD="${JCMD:-/root/.nix-profile/bin/jcmd}"
LOG_TAG="[attach-agent]"

log() { echo "$LOG_TAG $*" >&2; }

find_tws_pid() {
    # jcmd lists "pid class-name ...". Prefer the IBC main class.
    if [ ! -x "$JCMD" ]; then
        return 1
    fi
    "$JCMD" 2>/dev/null \
        | awk '/ibcalpha\.ibc\.IbcTws/{print $1; exit}'
}

attach_agent() {
    local pid="$1"
    if [ ! -f "$AGENT_SO" ]; then
        log "agent binary missing: $AGENT_SO"
        return 1
    fi
    log "attaching agent to pid=$pid ($AGENT_SO)"
    local out
    if ! out=$("$JCMD" "$pid" JVMTI.agent_load "$AGENT_SO" 2>&1); then
        log "jcmd agent_load failed: $out"
        return 1
    fi
    log "agent_load: $out"
    return 0
}

wait_for_key() {
    # Agent polls every 15s after a 3s startup delay; auth can take longer.
    local keys_dir="$JTS_ROOT/logs/keys"
    local i
    for i in $(seq 1 40); do
        if [ -L "$keys_dir/current" ] || ls "$keys_dir"/key-*.hex >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}

decrypt_all() {
    if [ ! -x "$DECRYPT_SCRIPT" ] && [ ! -f "$DECRYPT_SCRIPT" ]; then
        log "decrypt script missing: $DECRYPT_SCRIPT (skipping bulk decrypt)"
        return 0
    fi
    log "decrypting all .ibgzenc under $JTS_ROOT"
    # shellcheck disable=SC2086
    bash "$DECRYPT_SCRIPT" --all --root "$JTS_ROOT" || \
        log "bulk decrypt finished with errors (see above)"
}

last_pid=""
attached_for=""

log "starting (agent=$AGENT_SO delay=${ATTACH_DELAY_SEC}s poll=${POLL_SEC}s)"

while true; do
    pid="$(find_tws_pid || true)"
    if [ -n "${pid:-}" ]; then
        if [ "$pid" != "$last_pid" ]; then
            log "new TWS Java pid=$pid (was ${last_pid:-none})"
            last_pid="$pid"
            attached_for=""
            # Give the JVM time to leave early init / finish auth bootstrap.
            sleep "$ATTACH_DELAY_SEC"
            # Re-check: IBC may have restarted again during the delay.
            still="$(find_tws_pid || true)"
            if [ "$still" != "$pid" ]; then
                log "pid changed during attach delay ($pid -> ${still:-gone}); will retry"
                last_pid=""
                continue
            fi
            if attach_agent "$pid"; then
                attached_for="$pid"
                if wait_for_key; then
                    decrypt_all
                else
                    log "no key file yet after attach; will retry decrypt on next poll"
                fi
            fi
        elif [ "$attached_for" != "$pid" ]; then
            # Same PID as last observed but attach never succeeded.
            if attach_agent "$pid"; then
                attached_for="$pid"
            fi
        else
            # Steady state: re-decrypt so growing logs stay updated.
            decrypt_all
        fi
    else
        if [ -n "$last_pid" ]; then
            log "TWS Java gone (was pid $last_pid); waiting for restart"
        fi
        last_pid=""
        attached_for=""
    fi
    sleep "$POLL_SEC"
done
