# Performance & Smooth Fan Module (`rg477m_perf_tuning`)

## Why Stock V1.32 Needs Tuning
On Stock **V1.32**, `com.anbernic.control` configures MT6897 (Dimensity 8300) in a way that leaves performance on the table in everyday modes while creating excess fan noise:
1. **Balance mode (`bal`) caps Mali-G615 at `900 MHz`** (out of `1400 MHz`) and leaves conservative GED scaling margins, causing 3D frame drops unless you switch to loud Turbo mode.
2. **Game mode (`game`) locks CPU governors to `performance`**, keeping cores hot even in menus and light scenes.
3. **Stock `bal` / `turbo` fan modes react to raw 1-second `soc_max` spikes** without smoothing, causing constant revving up and down ("fan hunting").
4. **Stock ships with `debug.sf.disable_backpressure=1`**, which desynchronizes SurfaceFlinger and Mali-G615 and causes periodic ~1-second display flickers (`BLASTBufferQueue`).

## What `rg477m_perf_tuning` Changes

### 1. System Properties (`system.prop`)
- `debug.sf.disable_backpressure=0` — restores proper SurfaceFlinger backpressure on Mali-G615.
- `debug.sf.enable_gl_backpressure=0`, `debug.sf.predict_hwc_composition_strategy=0`, `debug.sf.enable_transaction_tracing=false` — aligns SurfaceFlinger with proven MT6897 (`duchamp`) settings.
- `ro.surface_flinger.uclamp.min=120`, `ro.surface_flinger.max_frame_buffer_acquired_buffers=4` — improves frame pacing under load.

### 2. Adaptive Performance Daemon (`rg477m_perf_daemon.sh`)
| Quick Panel Mode | CPU Policy | GPU / GED Policy | Idle & Screen Off |
| :--- | :--- | :--- | :--- |
| **`bal` (`mode=1`)** | `schedutil` (`rate_limit_us=1000`), `cpuidle=teo`, `top-app uclamp.min=45` | Unlocked `1400 MHz`, GED `margin=130`, `timer=50`, `step=15`, `floor=265 MHz` | Drops to `265 MHz` GPU / `400 MHz` CPU |
| **`game` (`mode=2`)** | Replaces stock `performance` with `schedutil` (`rate_limit_us=1000`), `uclamp.min=55`, mid-cluster floor `1400 MHz` | Unlocked `1400 MHz`, GED `margin=130`, `timer=40`, `step=18`, 3D floor `780 MHz` (`OPP 38`) | Drops to `265 MHz` GPU / `400 MHz` CPU on screen off |
| **`turbo` (`mode=3`)** | Stock clocks + `cpuidle=teo`, `uclamp.min=60` | Stock clocks + `margin=130` | Resets cleanly on screen off |
| **`saver` (`mode=0`)** | Conservative `schedutil` (`4000 us`), `uclamp=0` | Conservative margins (`530`), `floor=265 MHz` | Maximum battery saving |

### 3. Smooth EMA Fan Curves (`bal` & `turbo`)
When the quick panel fan mode is set to **`bal`** (`fan_mode=1`) or **`turbo`** (`fan_mode=2`), the daemon smooths the SoC temperature using an exponential moving average (~10s time constant) and ramps `/sys/devices/platform/pwm_fan/pwm_fan_set` gently (`+10` / `-6` PWM per 2s step, `±8` deadband):
- **`bal` curve:** `<48°C → 0` · `48–56°C → 65` · `56–64°C → 85` · `64–72°C → 110` · `72–80°C → 145` · `80–85°C → 200` · `>=85°C → 255`.
- **`turbo` curve:** `<42°C → 80` · `42–52°C → 115` · `52–60°C → 150` · `60–68°C → 185` · `68–76°C → 220` · `>=76°C → 255` (stops when screen is off and `<55°C`).
- **`silent` / `fixed`:** Handed straight back to the stock quick panel (`chmod 666`).

### 4. Safety & Measured Results
- **Thermal protection:** `thermal_core` is **never disabled**. Above `85 °C` (`<80 °C` hysteresis), the daemon backs off GPU ceiling to `900 MHz` and clears `uclamp` / GPU boosts.
- **Bootloop protection:** `post-fs-data.sh` counts incomplete boots and automatically disables the module after 2 failed boots.
- **Measured on RG477M V1.32 (heavy 3D Vulkan test in `bal` mode):** average FPS rose from **`56.1`** to **`60.03`**, GPU frame time dropped from **`12.46 ms`** to **`7.88 ms`** (-37%), average SoC temperature stayed at **`53.8 °C`** (battery `28.1 °C`), and system `BLASTBufferQueue` errors dropped to **0**.
