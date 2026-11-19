#!/system/bin/sh
MODDIR=${0%/*}
BOOTCOUNT_FILE="/data/adb/rg477m_perf_bootcount"

wait_sec=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$wait_sec" -lt 90 ]; do
    sleep 2
    wait_sec=$((wait_sec + 2))
done

rm -f "$BOOTCOUNT_FILE"

model=$(getprop ro.product.model)
if [ "$model" != "RG477M" ]; then
    exit 0
fi

sleep 3
sh "$MODDIR/rg477m_perf_daemon.sh" >/dev/null 2>&1 &
