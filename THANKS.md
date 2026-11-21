# Thanks & Acknowledgements

This toolkit builds upon knowledge, open-source tooling, and community research from the following projects:

- **Magisk** (`topjohnwu/Magisk`) — `magiskboot`, initramfs patching, `overlay.d`, and headless Magisk module framework (GPL-3.0). Bundled unmodified as `Magisk-v31.1.apk` inside the release archive.
- **Android Platform Tools (`adb`)** — Google Android SDK Platform-Tools for USB debugging and device communication (Apache-2.0). Bundled inside `runtime/adb/`.
- **MediaTek SP Flash Tool V6 & USB VCOM Drivers** — MediaTek flashing/readback utility (`SPFlashToolV6.exe`) and Windows VCOM driver installer bundled in `runtime/` for BROM/Preloader recovery and backup.
- **WPF-UI** (`lepoco/wpfui`) — Fluent Design UI components for .NET 8 desktop applications (MIT).
- **GammaOS / TheGammaSqueeze** — Anbernic RG477M MediaTek MT6897 partition reference, BROM/Preloader entry workflow, and thermal safety concepts.
- **Xiaomi `duchamp` (MT6897) device tree** — Reference GED HAL and `SurfaceFlinger` frame pacing tunables for Dimensity 8300 / Mali-G615.
- **Android Verified Boot (`avbtool`)** — AVB v1 descriptor format and AOSP `testkey_rsa2048` specification (Apache-2.0).
