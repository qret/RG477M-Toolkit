#!/system/bin/sh
# RG477M MT6897 Adaptive Performance, Frame Pacing & Smooth Fan Daemon (V1.32 verified)
# - Keeps thermal_core active, enforces LVTS-safe thermal backoff at >=85C.
# - Fixes CPU mid-cluster dips via real schedutil/rate_limit_us + uclamp.
# - Replaces jumpy stock Auto fan curve (fan_mode=1) with EMA-smoothed ramp (0..255).

GPU_DEV="/sys/devices/platform/soc/13000000.mali/devfreq/13000000.mali"
GED_HAL="/sys/kernel/ged/hal"
FIX_OPP="/proc/gpufreqv2/fix_target_opp_index"
UCLAMP_TOP="/dev/cpuctl/top-app/cpu.uclamp.min"
UCLAMP_LAT="/dev/cpuctl/top-app/cpu.uclamp.latency_sensitive"
CPUIDLE_GOV="/sys/devices/system/cpu/cpuidle/current_governor"
BL_FILE="/sys/class/leds/lcd-backlight/brightness"
FAN_NODE="/sys/devices/platform/pwm_fan/pwm_fan_set"

w() {
    [ -e "$1" ] && echo "$2" > "$1" 2>/dev/null || true
}

get_max_soc_temp() {
    max_t=0
    for tz in /sys/class/thermal/thermal_zone*; do
        [ -r "$tz/type" ] && [ -r "$tz/temp" ] || continue
        t=$(cat "$tz/type" 2>/dev/null)
        case "$t" in
            soc_max|soc-*|cpu-*|gpu1|gpu2) ;;
            *) continue ;;
        esac
        val=$(cat "$tz/temp" 2>/dev/null)
        case "$val" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$val" -gt 0 ] && [ "$val" -lt 200 ]; then
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
            apply_cpu_schedutil 1000 1400000
            w "$UCLAMP_TOP" 55
            w "$UCLAMP_LAT" 1
            ;;
        mode_0)
            w "$FIX_OPP" -1
            w "${GED_HAL}/custom_boost_gpu_freq" 64
            w "${GED_HAL}/dvfs_margin_value" 530
            w "${GED_HAL}/loading_base_dvfs_step" 4
            apply_cpu_schedutil 4000 400000
            w "$UCLAMP_TOP" 0
            w "$UCLAMP_LAT" 0
            ;;
        mode_3)
            w "$CPUIDLE_GOV" "teo"
            w "${GED_HAL}/custom_boost_gpu_freq" 64
            w "${GED_HAL}/dvfs_margin_value" 130
            w "$UCLAMP_TOP" 60
            w "$UCLAMP_LAT" 1
            ;;
    esac
}

calc_target_fan_pwm() {
    ema_t="$1"
    scr_on="$2"
    fmode="$3"

    if [ "$fmode" = "2" ]; then
        # Turbo smooth EMA curve: stronger airflow for heavy emulation, still silent when screen off & cool
        if [ "$scr_on" -le 0 ] && [ "$ema_t" -lt 55000 ]; then
            echo 0
        elif [ "$ema_t" -ge 76000 ]; then
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
    if [ "$scr_on" -le 0 ] && [ "$ema_t" -lt 60000 ]; then
        echo 0
    elif [ "$ema_t" -ge 85000 ]; then
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
in_thermal=0
ema_temp=0
cur_pwm=0
fan_owned=0
tick=0
cached_fan_mode="1"

while true; do
    bright=1
    if [ -r "$BL_FILE" ]; then
        bval=$(cat "$BL_FILE" 2>/dev/null)
        case "$bval" in
            ''|*[!0-9]*) bright=1 ;;
            *) bright=$bval ;;
        esac
    fi

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
            cur_max=$(cat "${GPU_DEV}/max_freq" 2>/dev/null)
            [ "$cur_max" != "1400000000" ] && need_reapply=1
        fi
        if [ -r "/sys/devices/system/cpu/cpufreq/policy7/scaling_governor" ]; then
            cur_gov=$(cat "/sys/devices/system/cpu/cpufreq/policy7/scaling_governor" 2>/dev/null)
            [ "$cur_gov" != "schedutil" ] && need_reapply=1
        fi
        [ "$need_reapply" -eq 1 ] && apply_profile "$target"
    fi

    # Smooth Auto Fan Controller (takes over only when stock fan_mode == 1 Auto)
    # Check settings every 3 ticks (~6s) to keep CPU overhead near zero
    if [ $((tick % 3)) -eq 0 ]; then
        fm=$(settings get system fan_mode 2>/dev/null)
        case "$fm" in
            0|1|2|3|4) cached_fan_mode="$fm" ;;
        esac
    fi

    if [ -e "$FAN_NODE" ]; then
        if [ "$cached_fan_mode" = "1" ] || [ "$cached_fan_mode" = "2" ]; then
            if [ "$fan_owned" -eq 0 ]; then
                # Lock out system uid (com.anbernic.control) while root daemon drives smooth bal/turbo EMA curve
                chmod 644 "$FAN_NODE" 2>/dev/null || true
                fan_owned=1
            fi
            tgt_pwm=$(calc_target_fan_pwm "$ema_temp" "$bright" "$cached_fan_mode")
            diff=$((tgt_pwm - cur_pwm))
            if [ "$tgt_pwm" -eq 0 ] && [ "$cur_pwm" -le 65 ]; then
                cur_pwm=0
                echo 0 > "$FAN_NODE" 2>/dev/null || true
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
        else
            if [ "$fan_owned" -eq 1 ]; then
                # Return full control to Anbernic Control for manual/off/max/custom modes
                chmod 666 "$FAN_NODE" 2>/dev/null || true
                fan_owned=0
            fi
        fi
    fi

    tick=$((tick + 1))
    sleep 2
done
