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
Write-Host '[ OK ] Magisk images flashed! Power on the console and verify Magisk app / su.' -ForegroundColor Green
