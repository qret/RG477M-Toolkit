#!/system/bin/sh
MODDIR=${0%/*}
BOOTCOUNT_FILE="/data/adb/rg477m_perf_bootcount"

count=0
if [ -f "$BOOTCOUNT_FILE" ]; then
    raw=$(cat "$BOOTCOUNT_FILE" 2>/dev/null)
    case "$raw" in
        ''|*[!0-9]*) count=0 ;;
        *) count=$raw ;;
    esac
fi

if [ "$count" -ge 2 ]; then
    touch "$MODDIR/disable"
    rm -f "$BOOTCOUNT_FILE"
    exit 0
fi

count=$((count + 1))
echo "$count" > "$BOOTCOUNT_FILE"
