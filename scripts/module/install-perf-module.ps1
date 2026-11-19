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
$zipPath = Join-Path $script:ProjectRoot ("build\rg477m-perf-module-v{0}.zip" -f $appVersion)

if (-not $Uninstall) {
    & (Join-Path $PSScriptRoot 'build-perf-module.ps1') -OutZip $zipPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build Magisk module zip.' }
}

if (-not $Execute -or $DryRun) {
    Write-Host ''
    Write-Host '=== DRY-RUN ПРЕДПРОСМОТР (без записи на устройство) ===' -ForegroundColor Yellow
    if ($Uninstall) {
        Write-Host '  Действие: пометить модуль rg477m_perf_tuning на удаление (/data/adb/modules/rg477m_perf_tuning/remove)'
    } else {
        Write-Host "  ZIP модуля: $zipPath"
        Write-Host '  Команда 1: adb push "<zip>" /data/local/tmp/rg477m-perf-module.zip'
        Write-Host '  Команда 2: adb shell su -c "magisk --install-module /data/local/tmp/rg477m-perf-module.zip"'
    }
    Write-Host '[INFO] Для реального применения добавьте флаг -Execute.' -ForegroundColor Cyan
    exit 0
}

if ($Uninstall) {
    Write-Host '[RUN] Помечаем модуль rg477m_perf_tuning на удаление...' -ForegroundColor Yellow
    $out = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', 'su -c "touch /data/adb/modules/rg477m_perf_tuning/remove && rm -f /data/adb/rg477m_perf_bootcount"')
    if ($LASTEXITCODE -ne 0) { throw "Uninstall failed: $out" }
    Write-Host '[ OK ] Модуль будет удалён при следующей перезагрузке консоли.' -ForegroundColor Green
    exit 0
}

Write-Host '[RUN] Копируем модуль на RG477M...' -ForegroundColor Cyan
$pushOut = Invoke-Adb -AdbExe $adb -AdbArgs @('push', $zipPath, '/data/local/tmp/rg477m-perf-module.zip')
Write-Host $pushOut
if ($LASTEXITCODE -ne 0) { throw "adb push failed: $pushOut" }

Write-Host '[RUN] Устанавливаем через magisk --install-module...' -ForegroundColor Cyan
$instOut = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', 'su -c "magisk --install-module /data/local/tmp/rg477m-perf-module.zip && rm -f /data/local/tmp/rg477m-perf-module.zip"')
Write-Host $instOut
if ($LASTEXITCODE -ne 0) { throw "magisk --install-module failed: $instOut" }

Write-Host '[ OK ] Модуль установлен! Перезагрузите RG477M для активации.' -ForegroundColor Green
