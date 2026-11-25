param(
    [ValidateSet('', '_a', '_b')]
    [string]$Slot = '',
    [ValidateSet(0, 128, 256)]
    [int]$StorageGB = 0,
    [string]$VbmetaImg = '',
    [switch]$Execute,
    [string]$SpftDir = '',
    [string]$DaDir = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\_common.ps1')

$resolved = Resolve-DeviceSlotAndStorage -ExplicitSlot $Slot -ExplicitStorageGB $StorageGB
$Slot = $resolved.Slot
$StorageGB = $resolved.StorageGB

$spftExe = Get-SpftExe -ExplicitDir $SpftDir
if (-not $spftExe) { throw 'SPFlashToolV6.exe not found.' }
$daRoot = Get-DaDir -ExplicitDir $DaDir
if (-not $daRoot) { throw 'DA/scatter directory not found.' }

$flashXml = Join-Path $daRoot ("download_agent\flash_{0}GB.xml" -f $StorageGB)
if (-not (Test-Path -LiteralPath $flashXml)) { throw "Flash XML not found: $flashXml" }

$buildDir = Join-Path $script:ProjectRoot 'build'
$backupDir = Join-Path $script:ProjectRoot 'backups\stock'
$logDir = Get-SpftLogDir
New-Item -ItemType Directory -Force -Path $buildDir, $logDir | Out-Null

$patchedInitBoot = Join-Path $buildDir ("init_boot{0}_magisk.img" -f $Slot)
if (-not (Test-Path -LiteralPath $patchedInitBoot)) {
    throw "Patched image not found: $patchedInitBoot. Run patch-init-boot.ps1 first!"
}
$stockBackupInitBoot = Join-Path $backupDir ("init_boot{0}.img" -f $Slot)
$stockBackupVbmeta   = Join-Path $backupDir ("vbmeta{0}.img" -f $Slot)
if (-not (Test-Path -LiteralPath $stockBackupInitBoot) -or -not (Test-Path -LiteralPath $stockBackupVbmeta)) {
    throw "Stock backups for slot $Slot missing in $backupDir. Refusing to flash without verified rollback!"
}

if (-not $VbmetaImg) {
    $VbmetaImg = Join-Path $buildDir ("vbmeta{0}_magisk.img" -f $Slot)
}
if (-not (Test-Path -LiteralPath $VbmetaImg)) {
    throw "Signed Magisk vbmeta image not found: $VbmetaImg. Run patch-init-boot.ps1 first!"
}

$initPart = "init_boot$Slot"
$vbPart   = "vbmeta$Slot"

$vbOffset   = if ($Slot -eq '_b') { '0x11608000' } else { '0xfe08000' }
$initOffset = if ($Slot -eq '_b') { '0x6d000000' } else { '0x43800000' }

$cfgXml = @"
<?xml version="1.0" encoding="utf-8"?>
<cflashtool-config version="1.0">
    <general>
        <connect-args baud_rate="" timeout_ms="600000" com_port_name="" com_port_type="USB-PCIE" version="1.0" conn_stage="2nd DA">
            <flash-xml>$flashXml</flash-xml>
            <auth-file></auth-file>
            <cert-file></cert-file>
        </connect-args>
        <runtime-parameter checksum_level="1" log_channel="USB" system_os="WINDOWS" da_log_level="INFO" battery_status="0" version="1.0"/>
        <log-info clean_hours="720" log_path="$logDir" version="1.0"/>
    </general>
    <commands>
        <WRITE-FLASH version="1.0" partition="UFS-LUA2" offset="$vbOffset">
            <source-file version="1.0" file_type="LOCAL_FILE" file_name="$VbmetaImg"/>
        </WRITE-FLASH>
        <WRITE-FLASH version="1.0" partition="UFS-LUA2" offset="$initOffset">
            <source-file version="1.0" file_type="LOCAL_FILE" file_name="$patchedInitBoot"/>
        </WRITE-FLASH>
        <REBOOT version="1.0" action="COLD-RESET"/>
    </commands>
</cflashtool-config>
"@

$cfgPath = Join-Path $buildDir ("flash_magisk{0}_config.xml" -f $Slot)
[System.IO.File]::WriteAllText($cfgPath, $cfgXml, [System.Text.UTF8Encoding]::new($false))

Write-Host "=== FLASH PLAN (Slot $Slot, ${StorageGB}GB) ===" -ForegroundColor Cyan
Write-Host "  1) $vbPart   <- $VbmetaImg"
Write-Host "  2) $initPart <- $patchedInitBoot"
Write-Host "  Rollback verified: $stockBackupVbmeta, $stockBackupInitBoot"
Write-Host "  Config: $cfgPath"

if (-not $Execute) {
    Write-Host '[DRY-RUN] Not flashing. Pass -Execute to write to device.' -ForegroundColor Yellow
    exit 0
}

Write-Host '=== STARTING SPFlashToolV6 (AUTO-PRELOADER / BROM) ===' -ForegroundColor Yellow
$adb = Get-AdbPath
if ($adb) {
    $st = Invoke-Adb -AdbExe $adb -AdbArgs @('get-state')
    if ($st -eq 'device') {
        Write-Host '[AUTO] ADB device detected -> sending "adb reboot" in 2s so Preloader VCOM catches automatically!' -ForegroundColor Cyan
        Start-Job -ScriptBlock { param($a) Start-Sleep -Seconds 2; & $a reboot } -ArgumentList $adb | Out-Null
    } else {
        Write-Host '[INFO] Simply reboot or power off the connected RG477M (Preloader VCOM will be caught automatically).' -ForegroundColor Cyan
    }
}
$rc = Invoke-SpftConfig -SpftExe $spftExe -ConfigPath $cfgPath
if ($rc -ne 0) {
    Write-Host "[FAIL] SPFlashToolV6 exited with code $rc" -ForegroundColor Red
    exit $rc
}
Write-Host '[ OK ] Образы Magisk прошиты (SPFlashToolV6).' -ForegroundColor Green

if (-not $adb) {
    Write-Host '[WARN] adb.exe не найден — включите консоль вручную и проверьте статус Magisk.' -ForegroundColor Yellow
    exit 0
}

function Wait-AndroidBoot {
    param([string]$AdbExe, [int]$TimeoutSeconds = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $st = Invoke-Adb -AdbExe $AdbExe -AdbArgs @('get-state')
        if ($LASTEXITCODE -eq 0 -and $st -eq 'device') {
            $booted = Invoke-Adb -AdbExe $AdbExe -AdbArgs @('shell', 'getprop', 'sys.boot_completed')
            if ($LASTEXITCODE -eq 0 -and $booted.Trim() -eq '1') {
                return $true
            }
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Wait-RootAccess {
    param([string]$AdbExe, [int]$Attempts = 5)
    $lastOut = ''
    for ($i = 1; $i -le $Attempts; $i++) {
        $lastOut = Invoke-Adb -AdbExe $AdbExe -AdbArgs @('shell', 'su -c id')
        if ($LASTEXITCODE -eq 0 -and $lastOut -match 'uid=0') {
            return @{ Ok = $true; Output = $lastOut }
        }
        if ($i -lt $Attempts) { Start-Sleep -Seconds 3 }
    }
    return @{ Ok = $false; Output = $lastOut }
}

Write-Host '[INFO] Ожидание загрузки RG477M после прошивки (до 90 с)... Если экран остался чёрным или на зарядке — включите консоль кнопкой Power.' -ForegroundColor Cyan
if (-not (Wait-AndroidBoot -AdbExe $adb -TimeoutSeconds 90)) {
    Write-Host '[WARN] Образы Magisk прошиты, но консоль не появилась по ADB за 90 с. Включите её кнопкой Power, дождитесь загрузки Android и нажмите «Обновить».' -ForegroundColor Yellow
    exit 0
}

$root = Wait-RootAccess -AdbExe $adb -Attempts 5
if ($root.Ok) {
    Write-Host '[ OK ] Magisk активен и root (uid=0) подтверждён! Можно переходить к Шагу 3.' -ForegroundColor Green
    exit 0
}

Write-Host '[INFO] Первый старт после прошивки завершён, но su ещё не активен — выполняем контрольную перезагрузку (adb reboot)...' -ForegroundColor Cyan
$null = Invoke-Adb -AdbExe $adb -AdbArgs @('reboot')
Start-Sleep -Seconds 5

if (-not (Wait-AndroidBoot -AdbExe $adb -TimeoutSeconds 90)) {
    Write-Host '[WARN] Образы Magisk прошиты, но после перезагрузки консоль не появилась по ADB за 90 с. Включите её кнопкой Power, дождитесь загрузки Android и нажмите «Обновить».' -ForegroundColor Yellow
    exit 0
}

$root = Wait-RootAccess -AdbExe $adb -Attempts 5
if ($root.Ok) {
    Write-Host '[ OK ] Magisk активен и root (uid=0) подтверждён после перезагрузки! Можно переходить к Шагу 3.' -ForegroundColor Green
    exit 0
}

$suOut = $root.Output
Write-Host "[WARN] Образы Magisk прошиты, но su пока не отвечает ('$suOut'). Перезагрузите консоль вручную или откройте приложение Magisk (разрешите Shell в «Суперпользователь») и нажмите «Обновить»." -ForegroundColor Yellow
exit 0
