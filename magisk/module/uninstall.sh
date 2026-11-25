#!/system/bin/sh
rm -f /data/adb/rg477m_perf_bootcount
settings delete global device_idle_constants 2>/dev/null || true
