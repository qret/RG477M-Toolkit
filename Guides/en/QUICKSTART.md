# Quick Start Guide (Anbernic RG477M — Stock V1.32)

## 1. Prerequisites
1. Download and extract **`RG477MToolkit.zip`** from **Releases** — it already bundles `ADB`, `SP Flash Tool V6`, RG477M Download Agent, `Magisk v31.1`, and the MediaTek USB driver installer in `runtime/`.
2. Run **`launch-ui.bat`** (or `RG477MToolkit.exe`). On first launch, the app automatically checks whether MediaTek VCOM & ADB drivers are installed; if they are missing, click **Install Drivers** on the top banner.
   *(If building from source instead of using the release ZIP, you can supply external tool paths via `local.paths.json` or environment variables `RG477M_ADB`, `RG477M_SPFT`, `RG477M_DA_DIR`, `RG477M_MAGISK_APK`.)*
3. Enable **USB Debugging** on your RG477M and authorize the PC.

## 2. Step-by-Step Setup
1. Launch `RG477MToolkit.exe` (or `launch-ui.bat`). Confirm the status badge shows **ADB Online** and build **V1.32**.
2. **Step 1 — Stock Firmware Backup:** click **Create Backup**. This saves `preloader_a/b`, `boot_a/b`, `init_boot_a/b`, `vbmeta_a/b`, and `seccfg` with `.sha256` checksums into `backups/stock/`. Once verified, the button turns green (**✓ Backup Ready**). Never skip this step!
3. **Step 2 — Install Magisk v31.1 Root:** click **Install Magisk**. The app automatically builds the patched `init_boot` + AOSP `testkey` `vbmeta` from your backup, reboots the device cleanly over ADB, and flashes via `PreLoader VCOM` without data wipe.
4. **Step 3 — Optimization Module:** once booted with Magisk, click **Install Module** (uses the pre-bundled ZIP directly) and reboot the handheld. Once installed, the button turns green (**✓ Installed**) and an **Uninstall** button appears if you ever want to remove it.

## 3. Manual BROM & Recovery Hints
- **Manual BROM entry:** power off the RG477M completely, hold **Vol+ and Vol- together (do NOT press Power!)**, and plug in the USB-C cable.
- **USB Error 43 (Device Descriptor Request Failed):** happens if `Power` was pressed during BROM entry. Unplug USB, hold `Power` for 15–20 seconds to force power off, then retry with only `Vol+` + `Vol-`.
- **1-Click Rollback:** click **Restore Stock** (or run `restore-stock-auto.bat`) to flash your original `vbmeta` and `init_boot` from `backups/stock/`.
