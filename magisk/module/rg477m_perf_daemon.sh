#!/system/bin/sh
# RG477M MT6897 Adaptive Performance, Power Saving & Smooth Fan Daemon (V1.32 verified)
# - Keeps thermal_core active, enforces LVTS-safe thermal backoff at >=85C.
# - Fixes CPU mid-cluster dips via real schedutil/rate_limit_us + uclamp.
# - Clamps background uclamp.max, tunes MGLRU/VM/UFS, and caps CPU/UFS clocks in sleep/saver.
# - Replaces jumpy stock Auto fan curves with EMA-smoothed ramps and instant 0 PWM in sleep.
# - Eliminates analog speaker pop/click (GPIO 5) via is_fm_enable without AudioFlinger timers.
# - Supports Doze tuning, logger/GPS/RIL stopping, and cgroup.freeze sleep via /data/adb/rg477m_stockfix.conf.

CONF_FILE="/data/adb/rg477m_stockfix.conf"
GPU_DEV="/sys/devices/platform/soc/13000000.mali/devfreq/13000000.mali"
GED_HAL="/sys/kernel/ged/hal"
FIX_OPP="/proc/gpufreqv2/fix_target_opp_index"
UFS_GOV="/sys/class/devfreq/112b0000.ufshci/governor"
UCLAMP_TOP="/dev/cpuctl/top-app/cpu.uclamp.min"
UCLAMP_LAT="/dev/cpuctl/top-app/cpu.uclamp.latency_sensitive"
CPUIDLE_GOV="/sys/devices/system/cpu/cpuidle/current_governor"
BL_FILE="/sys/class/leds/lcd-backlight/brightness"
FAN_NODE="/sys/devices/platform/pwm_fan/pwm_fan_set"
ANBERNIC_SETTINGS_XML="/data/data/com.anbernic.control/shared_prefs/cs_settings.xml"
AMP_NODE="/sys/devices/platform/11050000.mt6897-afe-pcm/is_fm_enable"
AFE_PM_NODE="/sys/devices/platform/11050000.mt6897-afe-pcm/power/runtime_status"
JACK_NODE="/sys/bus/platform/drivers/pmic-codec-accdet/state"

ENABLE_VM_UFS_TUNE=1
ENABLE_POWER_SETTINGS=1
ENABLE_DOZE_TUNE=1
ENABLE_SLEEP_FREEZE=1
SLEEP_FREEZE_DELAY_SEC=15
STOP_MTK_LOGGERS=1
STOP_GPS_DAEMONS=0
STOP_RIL_DAEMON=0
FREEZE_WHITELIST=""

EXEMPT_UIDS=""
THERMAL_TEMP_NODES=""
frozen_uids=""
apps_frozen=0
sleep_sec=0

w() {
    [ -e "$1" ] && echo "$2" > "$1" 2>/dev/null || true
}

load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        cat <<'EOF' > "$CONF_FILE" 2>/dev/null || true
# RG477M-StockFix configuration (1 = enabled, 0 = disabled)
# Changes take effect after module reload / device reboot.

# Tier 1: Cap background uclamp.max (30/50), MGLRU min_ttl_ms=1000, swappiness=60, UFS ra=256 / iostats=0
ENABLE_VM_UFS_TUNE=1

# Tier 1: Power-saving Android settings (mobile_data_always_on=0, disable wake gestures)
ENABLE_POWER_SETTINGS=1

# Tier 2: Enable & accelerate Android Doze mode (inactive_to=180s) for standby battery savings
ENABLE_DOZE_TUNE=1

# Tier 2: Freeze non-exempt user/background UIDs via cgroup.freeze after screen off
ENABLE_SLEEP_FREEZE=1
SLEEP_FREEZE_DELAY_SEC=15

# Tier 1: Stop MediaTek debug loggers and Perfetto trace daemons
STOP_MTK_LOGGERS=1

# Tier 2 (disabled by default): Stopping GNSS/LBS AIDL HALs causes system_server watchdog on Stock V1.32
STOP_GPS_DAEMONS=0

# Tier 2 (disabled by default): Keep disabled on Stock V1.32 unless tested safe on your build
STOP_RIL_DAEMON=0

# Space-separated package names or numeric UIDs excluded from cgroup.freeze (e.g. VPN/music player)
FREEZE_WHITELIST=""
EOF
        chmod 644 "$CONF_FILE" 2>/dev/null || true
    fi

    if [ -r "$CONF_FILE" ]; then
        . "$CONF_FILE" 2>/dev/null || true
    fi

    case "${SLEEP_FREEZE_DELAY_SEC:-}" in
        ''|*[!0-9]*) SLEEP_FREEZE_DELAY_SEC=15 ;;
    esac
}

build_freeze_exempt_uids() {
    EXEMPT_UIDS=" "
    base_pkgs="com.android.systemui com.anbernic.control com.anbernic.home com.anbernic.keymap com.google.android.inputmethod.latin com.android.inputmethod.latin com.topjohnwu.magisk"
    target_pkgs=""

    for item in $base_pkgs $FREEZE_WHITELIST; do
        case "$item" in
            '' ) continue ;;
            *[!0-9]* ) target_pkgs="$target_pkgs $item" ;;
            * ) EXEMPT_UIDS="${EXEMPT_UIDS}${item} " ;;
        esac
    done

    home_cmp=$(cmd package resolve-activity --brief -c android.intent.category.HOME -a android.intent.action.MAIN 2>/dev/null | tail -n 1)
    home_pkg=${home_cmp%%/*}
    case "$home_pkg" in
        ''|*[!A-Za-z0-9._-]*) ;;
        *) target_pkgs="$target_pkgs $home_pkg" ;;
    esac

    if [ -r "/data/system/packages.list" ] && [ -n "$target_pkgs" ]; then
        while read -r pkg uid _rest; do
            case "$uid" in
                ''|*[!0-9]*) continue ;;
            esac
            for wp in $target_pkgs; do
                if [ "$pkg" = "$wp" ]; then
                    case "$EXEMPT_UIDS" in
                        *" $uid "*) ;;
                        *) EXEMPT_UIDS="${EXEMPT_UIDS}${uid} " ;;
                    esac
                    break
                fi
            done
        done < /data/system/packages.list
    fi

    for wl in $(dumpsys deviceidle whitelist 2>/dev/null); do
        case "$wl" in
            user,*)
                wuid=${wl##*,}
                case "$wuid" in
                    ''|*[!0-9]*) ;;
                    *)
                        case "$EXEMPT_UIDS" in
                            *" $wuid "*) ;;
                            *) EXEMPT_UIDS="${EXEMPT_UIDS}${wuid} " ;;
                        esac
                        ;;
                esac
                ;;
        esac
    done
}

get_active_vpn_uids() {
    has_tun=0
    for nif in /sys/class/net/tun* /sys/class/net/wg* /sys/class/net/ppp*; do
        if [ -e "$nif" ]; then
            has_tun=1
            break
        fi
    done
    [ "$has_tun" -eq 0 ] && return

    vpns=$(dumpsys connectivity 2>/dev/null | awk '/VpnTransportInfo|IS_VPN/ { for(i=1;i<=NF;i++) if($i=="OwnerUid:" && $(i+1) ~ /^[0-9]+$/) print $(i+1) }')
    for wl in $(dumpsys deviceidle whitelist 2>/dev/null); do
        case "$wl" in
            user,*)
                wuid=${wl##*,}
                case "$wuid" in
                    ''|*[!0-9]*) ;;
                    *) vpns="$vpns $wuid" ;;
                esac
                ;;
        esac
    done
    echo "$vpns"
}

freeze_sleep_apps() {
    frozen_uids=""
    cur_exempt="${EXEMPT_UIDS} $(get_active_vpn_uids) "
    for d in /sys/fs/cgroup/uid_*; do
        [ -w "$d/cgroup.freeze" ] || continue
        uid=${d##*/uid_}
        case "$uid" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$uid" -lt 10000 ] && continue
        case "$cur_exempt" in
            *" $uid "*) continue ;;
        esac
        read -r cur_frz < "$d/cgroup.freeze" 2>/dev/null || cur_frz=""
        if [ "$cur_frz" != "1" ]; then
            if echo 1 > "$d/cgroup.freeze" 2>/dev/null; then
                frozen_uids="$frozen_uids $uid"
            fi
        fi
    done
}

unfreeze_sleep_apps() {
    if [ -n "$frozen_uids" ]; then
        for uid in $frozen_uids; do
            fnode="/sys/fs/cgroup/uid_${uid}/cgroup.freeze"
            [ -w "$fnode" ] && echo 0 > "$fnode" 2>/dev/null || true
        done
        frozen_uids=""
    fi
}

unfreeze_all_user_cgroups() {
    for d in /sys/fs/cgroup/uid_*; do
        [ -w "$d/cgroup.freeze" ] || continue
        uid=${d##*/uid_}
        case "$uid" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$uid" -lt 10000 ] && continue
        read -r cur_frz < "$d/cgroup.freeze" 2>/dev/null || cur_frz=""
        [ "$cur_frz" = "1" ] && echo 0 > "$d/cgroup.freeze" 2>/dev/null || true
    done
    frozen_uids=""
}

apply_boot_tweaks() {
    if [ "${ENABLE_VM_UFS_TUNE:-1}" -eq 1 ]; then
        w "/dev/cpuctl/background/cpu.uclamp.max" "30"
        w "/dev/cpuctl/system-background/cpu.uclamp.max" "50"
        w "/sys/kernel/mm/lru_gen/min_ttl_ms" "1000"
        w "/proc/sys/vm/swappiness" "60"
        w "/sys/block/sdc/queue/read_ahead_kb" "256"
        w "/sys/block/sdc/queue/iostats" "0"
    fi

    if [ "${ENABLE_POWER_SETTINGS:-1}" -eq 1 ]; then
        settings put global mobile_data_always_on 0 >/dev/null 2>&1 || true
        settings put secure doze_pulse_on_pick_up 0 >/dev/null 2>&1 || true
        settings put secure wake_gesture_enabled 0 >/dev/null 2>&1 || true
    fi

    if [ "${STOP_MTK_LOGGERS:-1}" -eq 1 ]; then
        for svc in mobile_log_d emdlogger traced traced_probes; do
            stop "$svc" 2>/dev/null || true
        done
    fi

    if [ "${STOP_GPS_DAEMONS:-0}" -eq 1 ]; then
        for svc in agpsd vendor.gnss-default mtk_lbs_service; do
            stop "$svc" 2>/dev/null || true
        done
    fi

    if [ "${STOP_RIL_DAEMON:-0}" -eq 1 ]; then
        stop vendor.ril-daemon-mtk 2>/dev/null || true
    fi

    if [ "${ENABLE_DOZE_TUNE:-1}" -eq 1 ]; then
        dumpsys deviceidle enable all >/dev/null 2>&1 || true
        settings put global device_idle_constants "light_after_inactive_to=60000,light_pre_idle_to=60000,light_idle_to=180000,inactive_to=180000,sensing_to=0,locating_to=0,location_accuracy=20.0,motion_inactive_to=0,idle_after_inactive_to=180000" >/dev/null 2>&1 || true
    fi
}

init_thermal_zones() {
    THERMAL_TEMP_NODES=""
    for tz in /sys/class/thermal/thermal_zone*; do
        [ -r "$tz/type" ] && [ -r "$tz/temp" ] || continue
        t=""
        read -r t < "$tz/type" 2>/dev/null || continue
        case "$t" in
            soc_max|soc-*|cpu-*|gpu1|gpu2)
                THERMAL_TEMP_NODES="${THERMAL_TEMP_NODES} ${tz}/temp"
                ;;
        esac
    done
}

get_max_soc_temp() {
    max_t=0
    [ -z "$THERMAL_TEMP_NODES" ] && init_thermal_zones
    for tnode in $THERMAL_TEMP_NODES; do
        val=""
        read -r val < "$tnode" 2>/dev/null || continue
        case "$val" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$val" -ge 15 ] && [ "$val" -lt 200 ]; then
            val=$((val * 1000))
        fi
        if [ "$val" -ge 1000 ] && [ "$val" -le 125000 ] && [ "$val" -gt "$max_t" ]; then
            max_t=$val
        fi
    done
    echo "$max_t"
}

apply_cpu_schedutil() {
    rate_us="$1"
    p4_min="$2"
    for pol in 0 4 7; do
        pdir="/sys/devices/system/cpu/cpufreq/policy${pol}"
        w "${pdir}/scaling_governor" "schedutil"
        w "${pdir}/schedutil/rate_limit_us" "$rate_us"
    done
    w "/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq" "$p4_min"
}

apply_profile() {
    state="$1"
    case "$state" in
        thermal_guard)
            w "$FIX_OPP" -1
            w "${GPU_DEV}/max_freq" 900000000
            w "${GED_HAL}/custom_boost_gpu_freq" 64
            w "${GED_HAL}/dvfs_margin_value" 530
            w "${GED_HAL}/loading_base_dvfs_step" 4
            w "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 2600000
            w "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 2800000
            w "$UFS_GOV" "simple_ondemand"
            apply_cpu_schedutil 2000 400000
            w "$UCLAMP_TOP" 0
            w "$UCLAMP_LAT" 0
            ;;
        screen_off)
            w "$FIX_OPP" -1
            w "${GED_HAL}/custom_boost_gpu_freq" 64
            w "${GED_HAL}/dvfs_margin_value" 530
            w "${GED_HAL}/loading_base_dvfs_step" 4
            apply_cpu_schedutil 4000 400000
            w "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 700000
            w "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 700000
            w "$UFS_GOV" "powersave"
            w "$UCLAMP_TOP" 0
            w "$UCLAMP_LAT" 0
            ;;
        mode_1)
            # Balance: unlock 1400 MHz GPU cap, fast schedutil + top-app uclamp (45), idle stays at 265/400 MHz
            w "$CPUIDLE_GOV" "teo"
            w "$FIX_OPP" -1
            w "${GPU_DEV}/max_freq" 1400000000
            w "${GED_HAL}/dvfs_margin_value" 130
            w "${GED_HAL}/timer_base_dvfs_margin" 50
            w "${GED_HAL}/loading_base_dvfs_step" 15
            w "${GED_HAL}/custom_boost_gpu_freq" 64
            w "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 3200000
            w "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 3350000
            w "$UFS_GOV" "simple_ondemand"
            apply_cpu_schedutil 1000 400000
            w "$UCLAMP_TOP" 45
            w "$UCLAMP_LAT" 1
            ;;
        mode_2)
            # Game: replace stock CPU performance lock with fast schedutil + uclamp (55) + p4 1.4 GHz floor
            # Eliminates 56-57 FPS mid-cluster dips without full-clock heat/fan whine
            w "$CPUIDLE_GOV" "teo"
            w "$FIX_OPP" -1
            w "${GPU_DEV}/max_freq" 1400000000
            w "${GED_HAL}/dvfs_margin_value" 130
            w "${GED_HAL}/timer_base_dvfs_margin" 40
            w "${GED_HAL}/loading_base_dvfs_step" 18
            w "${GED_HAL}/custom_boost_gpu_freq" 38
            w "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 3200000
            w "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 3350000
            w "$UFS_GOV" "simple_ondemand"
            apply_cpu_schedutil 1000 1400000
            w "$UCLAMP_TOP" 55
            w "$UCLAMP_LAT" 1
            ;;
        mode_0)
            w "$FIX_OPP" -1
            w "${GPU_DEV}/max_freq" 1400000000
            w "${GED_HAL}/custom_boost_gpu_freq" 64
            w "${GED_HAL}/dvfs_margin_value" 530
            w "${GED_HAL}/loading_base_dvfs_step" 4
            apply_cpu_schedutil 4000 400000
            w "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 700000
            w "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 700000
            w "$UFS_GOV" "powersave"
            w "$UCLAMP_TOP" 0
            w "$UCLAMP_LAT" 0
            ;;
        mode_3)
            w "$CPUIDLE_GOV" "teo"
            w "$FIX_OPP" -1
            w "${GPU_DEV}/max_freq" 1400000000
            w "${GED_HAL}/dvfs_margin_value" 130
            w "${GED_HAL}/timer_base_dvfs_margin" 40
            w "${GED_HAL}/loading_base_dvfs_step" 18
            w "${GED_HAL}/custom_boost_gpu_freq" 64
            w "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 3200000
            w "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 3350000
            w "$UFS_GOV" "simple_ondemand"
            apply_cpu_schedutil 1000 400000
            w "$UCLAMP_TOP" 60
            w "$UCLAMP_LAT" 1
            ;;
    esac
}

fast_wake_boost() {
    if [ "$in_thermal" -eq 1 ]; then
        w "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 2600000
        w "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 2800000
    else
        w "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 3200000
        w "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 3350000
    fi
    w "$UFS_GOV" "simple_ondemand"
    apply_cpu_schedutil 1000 400000
    w "$UCLAMP_TOP" 45
    w "$UCLAMP_LAT" 1
}

read_custom_fan_xml() {
    [ -r "$ANBERNIC_SETTINGS_XML" ] || return 1
    xml_line=""
    while read -r xml_line; do
        case "$xml_line" in
            *'custom_fan_speed&quot;:'*)
                v=${xml_line#*custom_fan_speed&quot;:}
                v=${v%%[!0-9]*}
                case "$v" in
                    ''|*[!0-9]*) return 1 ;;
                    *)
                        [ "$v" -gt 100 ] && v=100
                        cached_custom_fan="$v"
                        return 0
                        ;;
                esac
                ;;
        esac
    done < "$ANBERNIC_SETTINGS_XML"
    return 1
}

calc_target_fan_pwm() {
    ema_t="$1"
    scr_on="$2"
    fmode="$3"

    # Screen OFF: ALWAYS completely silent (0 PWM), prevent spinning in pockets/cases
    if [ "$scr_on" -le 0 ]; then
        echo 0
        return
    fi

    if [ "$fmode" = "2" ]; then
        # Turbo smooth EMA curve: stronger airflow for heavy emulation
        if [ "$ema_t" -ge 76000 ]; then
            echo 255
        elif [ "$ema_t" -ge 68000 ]; then
            echo 220
        elif [ "$ema_t" -ge 60000 ]; then
            echo 185
        elif [ "$ema_t" -ge 52000 ]; then
            echo 150
        elif [ "$ema_t" -ge 42000 ]; then
            echo 115
        else
            echo 80
        fi
        return
    fi

    # Balance smooth EMA curve (fan_mode == 1)
    if [ "$ema_t" -ge 85000 ]; then
        echo 255
    elif [ "$ema_t" -ge 80000 ]; then
        echo 200
    elif [ "$ema_t" -ge 72000 ]; then
        echo 145
    elif [ "$ema_t" -ge 64000 ]; then
        echo 110
    elif [ "$ema_t" -ge 56000 ]; then
        echo 85
    elif [ "$ema_t" -ge 48000 ]; then
        echo 65
    else
        echo 0
    fi
}

last_state=""
last_amp_state=""
in_thermal=0
ema_temp=0
cur_pwm=0
fan_owned=0
tick=0
heavy_tick=0
cached_fan_mode="1"
cached_custom_fan="50"

cleanup() {
    trap - INT TERM EXIT
    unfreeze_sleep_apps
    unfreeze_all_user_cgroups
    w "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 3200000
    w "/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 3350000
    w "$UFS_GOV" "simple_ondemand"
    [ -e "$AMP_NODE" ] && echo "0.1" > "$AMP_NODE" 2>/dev/null || true
    if [ "${fan_owned:-0}" -eq 1 ] && [ -e "$FAN_NODE" ]; then
        chmod 666 "$FAN_NODE" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup INT TERM EXIT

load_config
build_freeze_exempt_uids
init_thermal_zones
apply_boot_tweaks

while true; do
    bright=1
    if [ -r "$BL_FILE" ]; then
        read -r bval < "$BL_FILE" 2>/dev/null || bval=""
        case "$bval" in
            ''|*[!0-9]*) bright=1 ;;
            *) bright=$bval ;;
        esac
    fi

    woke_this_tick=0
    if [ "$bright" -gt 0 ]; then
        if [ "$last_state" = "screen_off" ]; then
            fast_wake_boost
            woke_this_tick=1
        fi
        if [ "$apps_frozen" -eq 1 ]; then
            unfreeze_sleep_apps
            apps_frozen=0
        fi
        sleep_sec=0
    fi

    # Click-free analog speaker amp control (no AudioFlinger standby timers):
    # - Screen ON & 3.5mm jack unplugged -> 1.0 (hold GPIO 5 amp ON; stock 3s DSP/DAC standby stays active)
    # - 3.5mm jack plugged -> 0.1 (route to headset & power off speaker amp immediately)
    # - Screen OFF & unplugged -> 0.1 unless background speaker playback is currently active (AFE runtime_status=active)
    want_amp="0.1"
    if [ -e "$AMP_NODE" ]; then
        jack_state=0
        if [ -r "$JACK_NODE" ]; then
            read -r jval < "$JACK_NODE" 2>/dev/null || jval=""
            case "$jval" in
                ''|*[!0-9]*) jack_state=0 ;;
                *) jack_state=$jval ;;
            esac
        fi

        if [ "$jack_state" -ne 0 ]; then
            want_amp="0.1"
        elif [ "$bright" -gt 0 ]; then
            want_amp="1.0"
        else
            afe_pm=""
            if [ -r "$AFE_PM_NODE" ]; then
                read -r afe_pm < "$AFE_PM_NODE" 2>/dev/null || afe_pm=""
            fi
            if [ "$last_amp_state" = "1.0" ] && [ "$afe_pm" = "active" ]; then
                want_amp="1.0"
            else
                want_amp="0.1"
            fi
        fi

        if [ "$want_amp" != "$last_amp_state" ]; then
            echo "$want_amp" > "$AMP_NODE" 2>/dev/null || true
            last_amp_state="$want_amp"
        fi
    fi

    run_heavy=0
    if [ "$bright" -le 0 ]; then
        # Screen OFF / sleep: kill fan immediately and restore node access for system
        if [ -e "$FAN_NODE" ]; then
            if [ "$cur_pwm" -ne 0 ]; then
                cur_pwm=0
                echo 0 > "$FAN_NODE" 2>/dev/null || true
            fi
            if [ "$fan_owned" -eq 1 ]; then
                chmod 666 "$FAN_NODE" 2>/dev/null || true
                fan_owned=0
            fi
        fi
        # 1s CLOCK_MONOTONIC sleep does not wake SoC from Suspend-to-RAM and cuts wake lag 3x
        loop_sleep=1
        # Run heavy loop only ONCE on screen-off transition to apply idle profile & power down
        if [ "$last_state" != "screen_off" ]; then
            run_heavy=1
        fi
        if [ "${ENABLE_SLEEP_FREEZE:-1}" -eq 1 ] && [ "$apps_frozen" -eq 0 ] && [ "$want_amp" != "1.0" ]; then
            sleep_sec=$((sleep_sec + loop_sleep))
            if [ "$sleep_sec" -ge "$SLEEP_FREEZE_DELAY_SEC" ]; then
                freeze_sleep_apps
                apps_frozen=1
            fi
        fi
    else
        loop_sleep=1
        if [ $((tick % 2)) -eq 0 ] || [ "$last_state" = "screen_off" ] || [ -z "$last_state" ]; then
            run_heavy=1
        fi
    fi

    if [ "$run_heavy" -eq 1 ]; then
        temp=$(get_max_soc_temp)
        if [ "$temp" -gt 0 ]; then
            if [ "$ema_temp" -eq 0 ]; then
                ema_temp=$temp
            else
                # EMA smoothing (~10s time constant at 2s loop) to stop fan hunting
                ema_temp=$(( (ema_temp * 3 + temp) / 4 ))
            fi
        fi

        if [ "$temp" -ge 85000 ]; then
            in_thermal=1
        elif [ "$in_thermal" -eq 1 ] && [ "$temp" -lt 80000 ]; then
            in_thermal=0
        fi

        if [ "$bright" -le 0 ]; then
            target="screen_off"
        elif [ "$in_thermal" -eq 1 ]; then
            target="thermal_guard"
        else
            mode=$(getprop persist.sys.cpu.mode)
            case "$mode" in
                0|1|2|3) target="mode_${mode}" ;;
                *) target="mode_1" ;;
            esac
        fi

        if [ "$target" != "$last_state" ]; then
            apply_profile "$target"
            last_state="$target"
        elif [ "$target" = "mode_1" ] || [ "$target" = "mode_2" ]; then
            need_reapply=0
            if [ -r "${GPU_DEV}/max_freq" ]; then
                cur_max=""
                read -r cur_max < "${GPU_DEV}/max_freq" 2>/dev/null || cur_max=""
                [ "$cur_max" != "1400000000" ] && need_reapply=1
            fi
            if [ -r "/sys/devices/system/cpu/cpufreq/policy7/scaling_governor" ]; then
                cur_gov=""
                read -r cur_gov < "/sys/devices/system/cpu/cpufreq/policy7/scaling_governor" 2>/dev/null || cur_gov=""
                [ "$cur_gov" != "schedutil" ] && need_reapply=1
            fi
            if [ -r "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" ]; then
                cur_p4max=""
                read -r cur_p4max < "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq" 2>/dev/null || cur_p4max=""
                case "$cur_p4max" in
                    ''|*[!0-9]*) ;;
                    *) [ "$cur_p4max" -le 700000 ] && need_reapply=1 ;;
                esac
            fi
            [ "$need_reapply" -eq 1 ] && apply_profile "$target"
        fi

        # Adaptive Fan Controller (takes over when screen is ON for fan_mode 1/2 EMA curves and 3/4 strict manual PWM)
        # Check settings every 3 heavy ticks (~6s) while screen is ON to keep CPU overhead near zero
        if [ "$bright" -gt 0 ] && [ "$woke_this_tick" -eq 0 ] && [ $((heavy_tick % 3)) -eq 0 ]; then
            fm=$(settings get system fan_mode 2>/dev/null)
            case "$fm" in
                0|1|2|3|4) cached_fan_mode="$fm" ;;
            esac
            if [ "$cached_fan_mode" = "3" ] || [ "$cached_fan_mode" = "4" ]; then
                cf=$(settings get system custom_fan_speed 2>/dev/null)
                case "$cf" in
                    ''|*[!0-9]*) ;;
                    *)
                        [ "$cf" -gt 100 ] && cf=100
                        cached_custom_fan="$cf"
                        ;;
                esac
            fi
        fi

        if [ "$bright" -gt 0 ] && [ -e "$FAN_NODE" ]; then
            if [ "$cached_fan_mode" = "1" ] || [ "$cached_fan_mode" = "2" ]; then
                if [ "$fan_owned" -eq 0 ]; then
                    # Lock out system uid (com.anbernic.control) while root daemon drives smooth bal/turbo EMA curve
                    chmod 644 "$FAN_NODE" 2>/dev/null || true
                    fan_owned=1
                fi
                tgt_pwm=$(calc_target_fan_pwm "$ema_temp" "$bright" "$cached_fan_mode")
                diff=$((tgt_pwm - cur_pwm))
                if [ "$tgt_pwm" -eq 0 ] && [ "$cur_pwm" -le 65 ]; then
                    if [ "$cur_pwm" -ne 0 ]; then
                        cur_pwm=0
                        echo 0 > "$FAN_NODE" 2>/dev/null || true
                    fi
                elif [ "$diff" -ge 8 ]; then
                    step=$diff
                    [ "$step" -gt 10 ] && step=10
                    cur_pwm=$((cur_pwm + step))
                    echo "$cur_pwm" > "$FAN_NODE" 2>/dev/null || true
                elif [ "$diff" -le -8 ]; then
                    step=$((-diff))
                    [ "$step" -gt 6 ] && step=6
                    cur_pwm=$((cur_pwm - step))
                    [ "$cur_pwm" -lt 0 ] && cur_pwm=0
                    echo "$cur_pwm" > "$FAN_NODE" 2>/dev/null || true
                fi
            elif [ "$cached_fan_mode" = "3" ] || [ "$cached_fan_mode" = "4" ]; then
                read_custom_fan_xml || true
                if [ "$fan_owned" -eq 0 ]; then
                    # Lock out Anbernic Control so its stock 65C -> 255 PWM override cannot cause fan spikes
                    chmod 644 "$FAN_NODE" 2>/dev/null || true
                    fan_owned=1
                fi
                tgt_pwm=$(( (cached_custom_fan * 255 + 50) / 100 ))
                [ "$tgt_pwm" -lt 0 ] && tgt_pwm=0
                [ "$tgt_pwm" -gt 255 ] && tgt_pwm=255
                if [ "$cur_pwm" -ne "$tgt_pwm" ]; then
                    cur_pwm=$tgt_pwm
                    echo "$cur_pwm" > "$FAN_NODE" 2>/dev/null || true
                fi
            else
                if [ "$fan_owned" -eq 1 ]; then
                    # Return full control to Anbernic Control for fan_mode=0 (off/silent)
                    chmod 666 "$FAN_NODE" 2>/dev/null || true
                    fan_owned=0
                fi
            fi
        fi

        heavy_tick=$((heavy_tick + 1))
    fi

    tick=$((tick + 1))
    sleep "$loop_sleep"
done
