param(
    [ValidateSet(0, 128, 256)]
    [int]$StorageGB = 0,
    [string]$SpftDir = '',
    [string]$DaDir = '',
    [switch]$GenerateOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\_common.ps1')

$adb = Get-AdbPath
if ($StorageGB -eq 0) {
    if (-not $adb) { throw 'adb.exe not found and -StorageGB not specified.' }
    $info = Assert-DeviceGuard -AdbExe $adb
    $StorageGB = $info.StorageGB
    Write-Host "[ OK ] Guard passed: $($info.Model) $($info.BuildId) slot=$($info.Slot) storage=${StorageGB}GB" -ForegroundColor Green
} else {
    Write-Host "[INFO] Manual storage mode: ${StorageGB}GB" -ForegroundColor Yellow
}

$spftExe = Get-SpftExe -ExplicitDir $SpftDir
if (-not $spftExe) { throw 'SPFlashToolV6.exe not found. Set RG477M_SPFT or local.paths.json.' }
$daRoot = Get-DaDir -ExplicitDir $DaDir
if (-not $daRoot) { throw 'DA/scatter directory not found. Set RG477M_DA_DIR or local.paths.json.' }

$flashXml = Join-Path $daRoot ("download_agent\flash_{0}GB.xml" -f $StorageGB)
if (-not (Test-Path -LiteralPath $flashXml)) { throw "Flash XML not found: $flashXml" }

$backupDir = Join-Path $script:ProjectRoot 'backups\stock'
$buildDir = Join-Path $script:ProjectRoot 'build'
$logDir = Get-SpftLogDir
New-Item -ItemType Directory -Force -Path $backupDir, $buildDir, $logDir | Out-Null

$targets = @(
    @{ Type = 'FLASH';     Name = 'UFS-LUA0';    File = 'preloader_a.bin'; Offset = '0x0'; Length = '0x100000'; MinBytes = 131072 },
    @{ Type = 'FLASH';     Name = 'UFS-LUA1';    File = 'preloader_b.bin'; Offset = '0x0'; Length = '0x100000'; MinBytes = 131072 },
    @{ Type = 'PARTITION'; Name = 'init_boot_b'; File = 'init_boot_b.img'; MinBytes = 1048576 },
    @{ Type = 'PARTITION'; Name = 'init_boot_a'; File = 'init_boot_a.img'; MinBytes = 1048576 },
    @{ Type = 'PARTITION'; Name = 'boot_b';      File = 'boot_b.img';      MinBytes = 16777216 },
    @{ Type = 'PARTITION'; Name = 'boot_a';      File = 'boot_a.img';      MinBytes = 16777216 },
    @{ Type = 'PARTITION'; Name = 'vbmeta_b';    File = 'vbmeta_b.img';    MinBytes = 4096 },
    @{ Type = 'PARTITION'; Name = 'vbmeta_a';    File = 'vbmeta_a.img';    MinBytes = 4096 },
    @{ Type = 'PARTITION'; Name = 'seccfg';      File = 'seccfg.img';      MinBytes = 4096 }
)

$cmdLines = New-Object System.Collections.Generic.List[string]
foreach ($t in $targets) {
    $outPath = Join-Path $backupDir $t.File
    if ($t.Type -eq 'PARTITION') {
        $cmdLines.Add("        <READ-PARTITION version=`"1.0`" partition=`"$($t.Name)`">")
        $cmdLines.Add("            <target-file version=`"1.0`" file_type=`"LOCAL_FILE`" file_name=`"$outPath`"/>")
        $cmdLines.Add("        </READ-PARTITION>")
    } else {
        $cmdLines.Add("        <READ-FLASH version=`"1.0`" partition=`"$($t.Name)`" offset=`"$($t.Offset)`" length=`"$($t.Length)`">")
        $cmdLines.Add("            <target-file version=`"1.0`" file_type=`"LOCAL_FILE`" file_name=`"$outPath`"/>")
        $cmdLines.Add("        </READ-FLASH>")
    }
}

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
$($cmdLines -join "`r`n")
        <REBOOT version="1.0" action="COLD-RESET"/>
    </commands>
</cflashtool-config>
"@

$cfgPath = Join-Path $buildDir 'readback_config.xml'
[System.IO.File]::WriteAllText($cfgPath, $cfgXml, [System.Text.UTF8Encoding]::new($false))
Write-Host "[ OK ] Generated Readback config: $cfgPath" -ForegroundColor Cyan

if ($GenerateOnly) {
    Write-Host '[INFO] -GenerateOnly specified, skipping SPFlashToolV6 execution.'
    exit 0
}

Write-Host ''
Write-Host '=== STARTING SPFlashToolV6 (READBACK / AUTO-PRELOADER) ===' -ForegroundColor Yellow
$adb = Get-AdbPath
if ($adb) {
    $st = Invoke-Adb -AdbExe $adb -AdbArgs @('get-state')
    if ($st -eq 'device') {
        Write-Host '[AUTO] ADB device detected -> sending "adb reboot" in 2s so Preloader VCOM catches automatically!' -ForegroundColor Cyan
        Start-Job -ScriptBlock { param($a) Start-Sleep -Seconds 2; & $a reboot } -ArgumentList $adb | Out-Null
    } else {
        Write-Host '[INFO] Reboot or power off the connected RG477M (Preloader VCOM will be caught automatically).' -ForegroundColor Cyan
    }
}
Write-Host 'Waiting for SPFlashToolV6...'
Write-Host ''

$rc = Invoke-SpftConfig -SpftExe $spftExe -ConfigPath $cfgPath

if ($rc -ne 0) {
    Write-Host "[FAIL] SPFlashToolV6 exited with code $rc. Check logs in $logDir" -ForegroundColor Red
    exit $rc
}

Write-Host '=== Verifying Readback dumps ===' -ForegroundColor Cyan
$ok = $true
foreach ($t in $targets) {
    $outPath = Join-Path $backupDir $t.File
    if (-not (Test-Path -LiteralPath $outPath)) {
        Write-Host "[FAIL] Missing: $($t.File)" -ForegroundColor Red
        $ok = $false
        continue
    }
    $sz = (Get-Item -LiteralPath $outPath).Length
    if ($sz -lt $t.MinBytes) {
        Write-Host "[FAIL] Truncated: $($t.File) ($sz bytes < $($t.MinBytes))" -ForegroundColor Red
        $ok = $false
        continue
    }
    $sha = (Get-FileHash -LiteralPath $outPath -Algorithm SHA256).Hash.ToLower()
    $sha | Out-File -Encoding ascii "$outPath.sha256"
    Write-Host ("[ OK ] {0,-16} {1,10} bytes  sha256={2}" -f $t.File, $sz, $sha.Substring(0, 16)) -ForegroundColor Green
}

if (-not $ok) { exit 1 }
Write-Host '[ OK ] Full stock Readback completed and verified!' -ForegroundColor Green
