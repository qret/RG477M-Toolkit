#!/system/bin/sh
# RG477M MT6897 Adaptive Performance, Frame Pacing & Smooth Fan Daemon (V1.32 verified)
# - Keeps thermal_core active, enforces LVTS-safe thermal backoff at >=85C.
# - Fixes CPU mid-cluster dips via real schedutil/rate_limit_us + uclamp.
# - Replaces jumpy stock Auto fan curve (fan_mode=1) with EMA-smoothed ramp (0..255).
# - Eliminates analog speaker pop/click (GPIO 5) via is_fm_enable without AudioFlinger timers.

GPU_DEV="/sys/devices/platform/soc/13000000.mali/devfreq/13000000.mali"
GED_HAL="/sys/kernel/ged/hal"
FIX_OPP="/proc/gpufreqv2/fix_target_opp_index"
UCLAMP_TOP="/dev/cpuctl/top-app/cpu.uclamp.min"
UCLAMP_LAT="/dev/cpuctl/top-app/cpu.uclamp.latency_sensitive"
CPUIDLE_GOV="/sys/devices/system/cpu/cpuidle/current_governor"
BL_FILE="/sys/class/leds/lcd-backlight/brightness"
FAN_NODE="/sys/devices/platform/pwm_fan/pwm_fan_set"
AMP_NODE="/sys/devices/platform/11050000.mt6897-afe-pcm/is_fm_enable"
AFE_PM_NODE="/sys/devices/platform/11050000.mt6897-afe-pcm/power/runtime_status"
JACK_NODE="/sys/bus/platform/drivers/pmic-codec-accdet/state"

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
            w "${GPU_DEV}/max_freq" 1400000000
            w "${GED_HAL}/custom_boost_gpu_freq" 64
            w "${GED_HAL}/dvfs_margin_value" 530
            w "${GED_HAL}/loading_base_dvfs_step" 4
            apply_cpu_schedutil 4000 400000
            w "$UCLAMP_TOP" 0
            w "$UCLAMP_LAT" 0
            ;;
        mode_3)
            w "$CPUIDLE_GOV" "teo"
            w "${GPU_DEV}/max_freq" 1400000000
            w "/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq" 400000
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

cleanup() {
    trap - INT TERM EXIT
    [ -e "$AMP_NODE" ] && echo "0.1" > "$AMP_NODE" 2>/dev/null || true
    if [ "${fan_owned:-0}" -eq 1 ] && [ -e "$FAN_NODE" ]; then
        chmod 666 "$FAN_NODE" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup INT TERM EXIT

while true; do
    bright=1
    if [ -r "$BL_FILE" ]; then
        read -r bval < "$BL_FILE" 2>/dev/null || bval=""
        case "$bval" in
            ''|*[!0-9]*) bright=1 ;;
            *) bright=$bval ;;
        esac
    fi

    # Click-free analog speaker amp control (no AudioFlinger standby timers):
    # - Screen ON & 3.5mm jack unplugged -> 1.0 (hold GPIO 5 amp ON; stock 3s DSP/DAC standby stays active)
    # - 3.5mm jack plugged -> 0.1 (route to headset & power off speaker amp immediately)
    # - Screen OFF & unplugged -> 0.1 unless background speaker playback is currently active (AFE runtime_status=active)
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
        loop_sleep=3
        # Run heavy loop only ONCE on screen-off transition to apply idle profile & power down
        if [ "$last_state" != "screen_off" ]; then
            run_heavy=1
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
                cur_max=$(cat "${GPU_DEV}/max_freq" 2>/dev/null)
                [ "$cur_max" != "1400000000" ] && need_reapply=1
            fi
            if [ -r "/sys/devices/system/cpu/cpufreq/policy7/scaling_governor" ]; then
                cur_gov=$(cat "/sys/devices/system/cpu/cpufreq/policy7/scaling_governor" 2>/dev/null)
                [ "$cur_gov" != "schedutil" ] && need_reapply=1
            fi
            [ "$need_reapply" -eq 1 ] && apply_profile "$target"
        fi

        # Smooth Auto Fan Controller (takes over only when screen is ON and stock fan_mode == 1 or 2)
        # Check settings every 3 heavy ticks (~6s) while screen is ON to keep CPU overhead near zero
        if [ "$bright" -gt 0 ] && [ $((heavy_tick % 3)) -eq 0 ]; then
            fm=$(settings get system fan_mode 2>/dev/null)
            case "$fm" in
                0|1|2|3|4) cached_fan_mode="$fm" ;;
            esac
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
            else
                if [ "$fan_owned" -eq 1 ]; then
                    # Return full control to Anbernic Control for manual/off/max/custom modes
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
