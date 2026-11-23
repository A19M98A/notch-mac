#!/usr/bin/env bash
# Standalone root-owned VPN core helper for Overlay (zero ocpanel/Python dependency).
# Installed to /usr/local/libexec/overlay-vpn-core.sh (root:wheel, 0755).
set -euo pipefail

CMD="${1:-}"
shift || true

case "$CMD" in
    start-singbox)
        BIN="$1"
        CFG="$2"
        PID_FILE="$3"
        LOG_FILE="$4"
        if [ -f "$PID_FILE" ]; then
            OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
            if [ -n "$OLD_PID" ]; then
                kill -TERM "$OLD_PID" 2>/dev/null || true
            fi
            rm -f "$PID_FILE"
        fi
        "$BIN" check -c "$CFG"
        nohup "$BIN" run -c "$CFG" >> "$LOG_FILE" 2>&1 < /dev/null &
        echo $! > "$PID_FILE"
        ;;
    start-openconnect)
        BIN="$1"
        PID_FILE="$2"
        SERVER="$3"
        USER_NAME="${4:-}"
        PASSWORD="${5:-}"
        EXTRA_ARGS="${6:-}"
        ARGS=("--background" "--non-inter" "--pid-file=$PID_FILE")
        if [ -n "$USER_NAME" ]; then
            ARGS+=("--user" "$USER_NAME")
        fi
        if [ -n "$EXTRA_ARGS" ]; then
            # shellcheck disable=SC2206
            EXTRA_ARR=($EXTRA_ARGS)
            ARGS+=("${EXTRA_ARR[@]}")
        fi
        if [ -n "$PASSWORD" ]; then
            ARGS+=("--passwd-on-stdin")
            printf '%s\n' "$PASSWORD" | "$BIN" "${ARGS[@]}" "$SERVER"
        else
            "$BIN" "${ARGS[@]}" "$SERVER"
        fi
        ;;
    stop-pid)
        PID="$1"
        PID_FILE="${2:-}"
        kill -TERM "$PID" 2>/dev/null || true
        if [ -n "$PID_FILE" ]; then
            rm -f "$PID_FILE"
        fi
        ;;
    stop-all)
        SB_PID="${1:-}"
        OC_PID="${2:-}"
        pkill -TERM -f "sing-box run" 2>/dev/null || true
        pkill -TERM openconnect 2>/dev/null || true
        [ -n "$SB_PID" ] && rm -f "$SB_PID"
        [ -n "$OC_PID" ] && rm -f "$OC_PID"
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        exit 1
        ;;
esac
