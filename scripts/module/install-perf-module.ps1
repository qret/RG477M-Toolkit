param(
    [switch]$DryRun,
    [switch]$Execute,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\_common.ps1')

$adb = Get-AdbPath
if (-not $adb) { throw 'adb.exe not found. Set RG477M_ADB or local.paths.json.' }

$info = Assert-DeviceGuard -AdbExe $adb
Write-Host "[ OK ] Guard passed: $($info.Model) $($info.BuildId) slot=$($info.Slot)" -ForegroundColor Green

$suCheck = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', 'su -c id')
if ($suCheck -notmatch 'uid=0') {
    throw "Root access (su -c id) is required. Got: '$suCheck'. Complete Magisk setup first."
}

$versionPropsPath = Join-Path $script:ProjectRoot 'version.properties'
$appVersion = '0.1.0'
if (Test-Path -LiteralPath $versionPropsPath) {
    foreach ($line in (Get-Content -LiteralPath $versionPropsPath)) {
        if ($line -match '^\s*APP_VERSION\s*=\s*(.+)$') { $appVersion = $Matches[1].Trim() }
    }
}
$zipName = "rg477m-perf-module-v{0}.zip" -f $appVersion
$bundledZip = Join-Path $script:ProjectRoot ("magisk\{0}" -f $zipName)
$buildZip = Join-Path $script:ProjectRoot ("build\{0}" -f $zipName)
$moduleSrcDir = Join-Path $script:ProjectRoot 'magisk\module'

$zipPath = if (Test-Path -LiteralPath $bundledZip) { $bundledZip } else { $buildZip }

if (-not $Uninstall) {
    $needBuild = -not (Test-Path -LiteralPath $zipPath)
    if (-not $needBuild -and (Test-Path -LiteralPath $moduleSrcDir)) {
        $zipTime = (Get-Item -LiteralPath $zipPath).LastWriteTimeUtc
        $newerSrc = Get-ChildItem -LiteralPath $moduleSrcDir -Recurse -File | Where-Object { $_.LastWriteTimeUtc -gt $zipTime } | Select-Object -First 1
        if ($newerSrc) { $needBuild = $true }
    }
    if ($needBuild) {
        $zipPath = $buildZip
        & (Join-Path $PSScriptRoot 'build-perf-module.ps1') -OutZip $zipPath
    } else {
        Write-Host "[ OK ] Используется готовый ZIP модуля: $zipPath" -ForegroundColor Green
    }
}

if (-not $Execute -or $DryRun) {
    Write-Host ''
    Write-Host '=== DRY-RUN ПРЕДПРОСМОТР (без записи на устройство) ===' -ForegroundColor Yellow
    if ($Uninstall) {
        Write-Host '  Действие: пометить модуль rg477m_perf_tuning на удаление (/data/adb/modules/rg477m_perf_tuning/remove)'
    } else {
        Write-Host "  ZIP модуля: $zipPath"
        Write-Host '  Команда 1: adb push "<zip>" /data/local/tmp/rg477m-perf-module.zip'
        Write-Host '  Команда 2: adb shell su -c ''magisk --install-module /data/local/tmp/rg477m-perf-module.zip'''
    }
    Write-Host '[INFO] Для реального применения добавьте флаг -Execute.' -ForegroundColor Cyan
    exit 0
}

if ($Uninstall) {
    Write-Host '[RUN] Помечаем модуль rg477m_perf_tuning на удаление...' -ForegroundColor Yellow
    $out = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', "su -c 'touch /data/adb/modules/rg477m_perf_tuning/remove'")
    if ($LASTEXITCODE -ne 0) { throw "Uninstall failed: $out" }
    $null = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', "su -c 'rm -f /data/adb/rg477m_perf_bootcount'")
    Write-Host '[ OK ] Модуль будет удалён при следующей перезагрузке консоли.' -ForegroundColor Green
    exit 0
}

$ufCheck = (Invoke-Adb -AdbExe $adb -AdbArgs @('shell', "su -c 'test -f /data/adb/magisk/util_functions.sh && echo OK || echo MISS'")).Trim()
if ($ufCheck -ne 'OK') {
    Write-Host '[INFO] /data/adb/magisk/util_functions.sh отсутствует — подготавливаю файлы Magisk...' -ForegroundColor Cyan
    $magiskApk = Resolve-ToolPath -EnvVarName 'RG477M_MAGISK_APK' -LocalCfgKey 'magisk_apk' -RelativeCandidates @('runtime\magisk\Magisk-v31.1.apk', 'magisk\apk\Magisk-v31.1.apk', 'magisk\Magisk.apk')
    if (-not $magiskApk) {
        throw 'util_functions.sh missing in /data/adb/magisk and Magisk APK not found on PC.'
    }
    $pmOut = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', 'pm path com.topjohnwu.magisk')
    if ($LASTEXITCODE -ne 0 -or $pmOut -notmatch 'package:') {
        $instApkOut = Invoke-Adb -AdbExe $adb -AdbArgs @('install', '-r', $magiskApk)
        if ($LASTEXITCODE -ne 0 -or $instApkOut -notmatch 'Success') {
            throw "adb install Magisk APK failed: $instApkOut"
        }
    }
    $setupCmd = @'
APK=$(pm path com.topjohnwu.magisk 2>/dev/null | head -n 1 | cut -d: -f2)
MB=/data/adb/magisk
mkdir -p "$MB" && chmod 700 /data/adb
if [ -n "$APK" ] && [ -f "$APK" ]; then
  TMP=/data/local/tmp/mg_uf
  rm -rf "$TMP" && mkdir -p "$TMP"
  unzip -q -o "$APK" -d "$TMP" 2>/dev/null
  for pair in "libmagiskboot.so:magiskboot" "libmagiskinit.so:magiskinit" "libmagisk.so:magisk" "libmagiskpolicy.so:magiskpolicy" "libbusybox.so:busybox" "libinit-ld.so:init-ld"; do
    src="$TMP/lib/arm64-v8a/${pair%:*}"; dst="$MB/${pair#*:}"
    [ -f "$src" ] && cp -af "$src" "$dst"
  done
  for f in util_functions.sh boot_patch.sh addon.d.sh stub.apk; do
    [ -f "$TMP/assets/$f" ] && cp -af "$TMP/assets/$f" "$MB/$f"
  done
  chmod -R 755 "$MB" && chown -R 0:0 "$MB"
  rm -rf "$TMP"
fi
'@
    ($setupCmd.Replace("`r`n", "`n") + "`n") | & $adb shell "su -c sh"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to populate /data/adb/magisk.' }
}

Write-Host '[RUN] Копируем модуль на RG477M...' -ForegroundColor Cyan
$pushOut = Invoke-Adb -AdbExe $adb -AdbArgs @('push', $zipPath, '/data/local/tmp/rg477m-perf-module.zip')
Write-Host $pushOut
if ($LASTEXITCODE -ne 0) { throw "adb push failed: $pushOut" }

Write-Host '[RUN] Устанавливаем через magisk --install-module...' -ForegroundColor Cyan
$instOut = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', "su -c 'magisk --install-module /data/local/tmp/rg477m-perf-module.zip'")
$instRc = $LASTEXITCODE
Write-Host $instOut
$null = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', 'rm -f /data/local/tmp/rg477m-perf-module.zip')
if ($instRc -ne 0) { throw "magisk --install-module failed: $instOut" }

Write-Host '[ OK ] Модуль установлен! Перезагрузите RG477M для активации.' -ForegroundColor Green
