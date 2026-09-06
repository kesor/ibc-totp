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

# Remove stale Chromium single-instance locks from a prior TWS run.
#
# TWS renders the TradingView chart through JxBrowser (embedded
# Chromium). When TWS shuts down -- graceful or otherwise -- it
# sometimes leaves the three Chromium singleton files behind in the
# persistent user-data directory:
#   $JTS_ROOT/<user-hash>/tvChartSettings{,_temp}/
#     SingletonLock    -> <hostname>-<pid>
#     SingletonCookie  -> <random-id>
#     SingletonSocket  -> /tmp/.org.chromium.Chromium.<rand>/SingletonSocket
#
# On the next start, JxBrowser sees SingletonLock still pointing at
# a now-dead PID and refuses to start a new engine:
#   com.teamdev.jxbrowser.engine.UserDataDirectoryAlreadyInUseException:
#     The user data directory is already in use: .../tvChartSettings_temp
# That kills the TradingView chart ("Can't create JxBrowser" in the
# TWS log) -- everything else in TWS keeps working, but the big
# browser-based chart window stays blank.
#
# Fix: when we observe TWS Java gone, before the next start, delete
# the three singleton files IF their claimed PID is dead. Never
# touch the rest of tvChartSettings/ -- the Default/ profile holds
# chart templates, watchlist layout, cookies, etc. and we want all
# of that preserved across restarts.
#
# Safe because the live TWS chromium never uses tvChartSettings/
# directly -- it always runs against a fresh /tmp/JxBrowser-UserData-<uuid>
# (verified: --user-data-dir=/tmp/JxBrowser-UserData-* in the
# chromium cmdline). tvChartSettings is only ever read/written at
# session boundaries, i.e. when TWS is down. So at the moment we
# call this function, no chromium process anywhere on this host is
# holding the lock.
clean_stale_jxbrowser_locks() {
    local d lockfile locktarget pid
    # Find every tvChartSettings* dir under the JTS root. Two layers
    # deep is enough: <root>/<user-hash>/tvChartSettings{,_temp}
    # shellcheck disable=SC2044
    for d in $(find "$JTS_ROOT" -mindepth 2 -maxdepth 3 -type d \
                   \( -name tvChartSettings -o -name 'tvChartSettings_temp*' \) \
                   2>/dev/null); do
        lockfile="$d/SingletonLock"
        [ -L "$lockfile" ] || continue
        # Target format: <hostname>-<pid>. The hostname can contain
        # hyphens (e.g. "a1b2c3d4e5f6") but the last hyphen-separated
        # field is always the PID. Read the symlink target verbatim --
        # readlink handles the case where it points nowhere, which is
        # itself evidence the lock is stale.
        locktarget="$(readlink "$lockfile" 2>/dev/null || true)"
        [ -n "$locktarget" ] || {
            log "cleaning lock in $d (SingletonLock target unreadable)"
            rm -f "$d/SingletonLock" "$d/SingletonCookie" "$d/SingletonSocket" \
                2>/dev/null || true
            continue
        }
        pid="${locktarget##*-}"
        case "$pid" in
            ''|*[!0-9]*) log "cleaning lock in $d (SingletonLock target='$locktarget' has no numeric pid)"; rm -f "$d/SingletonLock" "$d/SingletonCookie" "$d/SingletonSocket" 2>/dev/null || true; continue;;
        esac
        if kill -0 "$pid" 2>/dev/null; then
            # A live process holds this PID. Could be a coincidental
            # PID reuse, or could be a real chromium another TWS
            # instance is using. Either way: do not touch. Log so a
            # human can investigate if charts are still broken.
            log "NOT cleaning $d -- SingletonLock target pid $pid is alive"
            continue
        fi
        log "cleaning stale jxbrowser lock in $d (dead pid=$pid)"
        rm -f "$d/SingletonLock" "$d/SingletonCookie" "$d/SingletonSocket" \
            2>/dev/null || true
    done
}

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
            clean_stale_jxbrowser_locks
        fi
        last_pid=""
        attached_for=""
    fi
    sleep "$POLL_SEC"
done
