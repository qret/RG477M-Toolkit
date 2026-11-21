param(
    [string]$Slot = '',
    [string]$MagiskApk = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\_common.ps1')

$adb = Get-AdbPath
if (-not $adb) { throw 'adb.exe not found.' }
$info = Assert-DeviceGuard -AdbExe $adb
if (-not $Slot) { $Slot = $info.Slot }

if (-not $MagiskApk) {
    $MagiskApk = Resolve-ToolPath -EnvVarName 'RG477M_MAGISK_APK' -LocalCfgKey 'magisk_apk' -RelativeCandidates @('runtime\magisk\Magisk-v31.1.apk', 'magisk\apk\Magisk-v31.1.apk', 'magisk\Magisk.apk')
}
if (-not $MagiskApk -or -not (Test-Path -LiteralPath $MagiskApk)) {
    throw 'Magisk APK not found. Place Magisk-v31.1.apk in magisk/apk/ or set local.paths.json.'
}

$stockImg = Join-Path $script:ProjectRoot ("backups\stock\init_boot{0}.img" -f $Slot)
if (-not (Test-Path -LiteralPath $stockImg)) {
    throw "Stock backup not found: $stockImg. Run readback-stock.ps1 first!"
}
$shaFile = "$stockImg.sha256"
if (Test-Path -LiteralPath $shaFile) {
    $want = (Get-Content -LiteralPath $shaFile -Raw).Trim().ToLower()
    $have = (Get-FileHash -LiteralPath $stockImg -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $have) { throw "SHA-256 mismatch on $stockImg!" }
}

function Invoke-AdbChecked {
    param([string[]]$AdbArgs)
    $out = Invoke-Adb -AdbExe $adb -AdbArgs $AdbArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ADB command failed (exit $LASTEXITCODE): adb $($AdbArgs -join ' ')`n$out"
    }
    return $out
}

$pmOut = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', 'pm path com.topjohnwu.magisk')
if ($LASTEXITCODE -ne 0 -or $pmOut -notmatch 'package:') {
    Write-Host '[INFO] Installing Magisk app APK on RG477M...' -ForegroundColor Cyan
    $instApkOut = Invoke-Adb -AdbExe $adb -AdbArgs @('install', '-r', $MagiskApk)
    if ($LASTEXITCODE -ne 0 -or $instApkOut -notmatch 'Success') {
        throw "adb install Magisk APK failed: $instApkOut"
    }
    Write-Host "[ OK ] $instApkOut" -ForegroundColor Green
}

$buildDir = Join-Path $script:ProjectRoot 'build'
$extractDir = Join-Path $buildDir 'magisk_extract'
$zipCopy = Join-Path $buildDir 'magisk_tmp.zip'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
Copy-Item -LiteralPath $MagiskApk -Destination $zipCopy -Force
Expand-Archive -LiteralPath $zipCopy -DestinationPath $extractDir -Force
Remove-Item -LiteralPath $zipCopy -Force

$L64 = Join-Path $extractDir 'lib\arm64-v8a'
$L32 = Join-Path $extractDir 'lib\armeabi-v7a'
$A   = Join-Path $extractDir 'assets'
if (-not (Test-Path -LiteralPath $L64)) { throw 'Magisk APK has no lib/arm64-v8a.' }

# Headless auto-setup script + init.rc for overlay.d:
# 1) Populates /data/adb/magisk/* on boot (eliminates "Requires Additional Setup" prompt in Magisk app)
# 2) Grants automatic root to ADB shell (uid=2000) in /data/adb/magisk.db without screen prompt
$rcContent = "on property:sys.boot_completed=1`n    exec u:r:magisk:s0 root root -- /system/bin/sh `${MAGISKTMP}/rg477m_setup.sh`n"
$shLines = @(
    '#!/system/bin/sh',
    'MB=/data/adb/magisk',
    'mkdir -p $MB',
    'chmod 700 /data/adb',
    'if [ ! -f "$MB/util_functions.sh" ] || [ ! -f "$MB/magiskboot" ]; then',
    '  APK=$(pm path com.topjohnwu.magisk 2>/dev/null | head -n 1 | cut -d: -f2)',
    '  if [ -n "$APK" ] && [ -f "$APK" ]; then',
    '    TMP=/data/local/tmp/mg_auto',
    '    rm -rf $TMP && mkdir -p $TMP',
    '    unzip -q -o "$APK" -d $TMP 2>/dev/null',
    '    for pair in "libmagiskboot.so:magiskboot" "libmagiskinit.so:magiskinit" "libmagisk.so:magisk" "libmagiskpolicy.so:magiskpolicy" "libbusybox.so:busybox" "libinit-ld.so:init-ld"; do',
    '      src="$TMP/lib/arm64-v8a/${pair%:*}"',
    '      dst="$MB/${pair#*:}"',
    '      [ -f "$src" ] && cp -af "$src" "$dst"',
    '    done',
    '    [ -f "$TMP/lib/armeabi-v7a/libmagisk.so" ] && cp -af "$TMP/lib/armeabi-v7a/libmagisk.so" "$MB/magisk32"',
    '    for f in util_functions.sh boot_patch.sh addon.d.sh stub.apk; do',
    '      [ -f "$TMP/assets/$f" ] && cp -af "$TMP/assets/$f" "$MB/$f"',
    '    done',
    '    chmod -R 755 $MB',
    '    chown -R 0:0 $MB',
    '    rm -rf $TMP',
    '  fi',
    'fi',
    'magisk --restorecon >/dev/null 2>&1',
    'magisk --sqlite "CREATE TABLE IF NOT EXISTS policies (uid INT, policy INT, until INT, logging INT, notification INT, PRIMARY KEY(uid)); REPLACE INTO policies VALUES(2000, 2, 0, 1, 0);" >/dev/null 2>&1',
    'exit 0'
)
$shContent = ($shLines -join "`n") + "`n"

$rcPath = Join-Path $buildDir 'init.rg477m.rc'
$shPath = Join-Path $buildDir 'rg477m_setup.sh'
[System.IO.File]::WriteAllText($rcPath, $rcContent, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($shPath, $shContent, [System.Text.UTF8Encoding]::new($false))

Write-Host "[INFO] Pushing Magisk tools & stock init_boot$Slot to /data/local/tmp/mgpatch..." -ForegroundColor Cyan
Invoke-AdbChecked @('shell', 'rm -rf /data/local/tmp/mgpatch && mkdir -p /data/local/tmp/mgpatch') | Out-Null

$map64 = @{
    'libmagiskboot.so'   = 'magiskboot'
    'libmagiskinit.so' = 'magiskinit'
    'libmagisk.so'       = 'magisk'
    'libmagiskpolicy.so' = 'magiskpolicy'
    'libbusybox.so'      = 'busybox'
    'libinit-ld.so'      = 'init-ld'
}
foreach ($k in $map64.Keys) {
    $src = Join-Path $L64 $k
    if (Test-Path -LiteralPath $src) {
        Invoke-AdbChecked @('push', $src, ("/data/local/tmp/mgpatch/" + $map64[$k])) | Out-Null
    }
}
$m32 = Join-Path $L32 'libmagisk.so'
if (Test-Path -LiteralPath $m32) {
    Invoke-AdbChecked @('push', $m32, '/data/local/tmp/mgpatch/magisk32') | Out-Null
}
foreach ($f in @('boot_patch.sh', 'util_functions.sh', 'stub.apk')) {
    $src = Join-Path $A $f
    if (Test-Path -LiteralPath $src) {
        Invoke-AdbChecked @('push', $src, "/data/local/tmp/mgpatch/$f") | Out-Null
    }
}
Invoke-AdbChecked @('push', $rcPath, '/data/local/tmp/mgpatch/init.rg477m.rc') | Out-Null
Invoke-AdbChecked @('push', $shPath, '/data/local/tmp/mgpatch/rg477m_setup.sh') | Out-Null
Invoke-AdbChecked @('push', $stockImg, '/data/local/tmp/mgpatch/init_boot.img') | Out-Null

Write-Host "[INFO] Patching init_boot$Slot with PREINITDEVICE=metadata and headless overlay.d..." -ForegroundColor Cyan
$runPatchLines = @(
    '#!/system/bin/sh',
    'set -e',
    'cd /data/local/tmp/mgpatch',
    'chmod 755 magiskboot magiskinit magisk busybox init-ld rg477m_setup.sh 2>/dev/null || true',
    'PREINITDEVICE=metadata KEEPVERITY=true KEEPFORCEENCRYPT=true BOOTMODE=false sh ./boot_patch.sh init_boot.img',
    './magiskboot unpack new-boot.img',
    './magiskboot cpio ramdisk.cpio "add 0644 overlay.d/init.rg477m.rc init.rg477m.rc" "add 0750 overlay.d/sbin/rg477m_setup.sh rg477m_setup.sh"',
    './magiskboot cpio ramdisk.cpio "exists overlay.d/init.rg477m.rc"',
    './magiskboot cpio ramdisk.cpio "exists overlay.d/sbin/rg477m_setup.sh"',
    'echo "=== overlay.d contents ==="',
    './magiskboot cpio ramdisk.cpio "ls -r overlay.d"',
    './magiskboot repack new-boot.img new-boot-headless.img',
    'mv -f new-boot-headless.img new-boot.img'
)
$runPatchPath = Join-Path $buildDir 'run_patch.sh'
[System.IO.File]::WriteAllText($runPatchPath, (($runPatchLines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
Invoke-AdbChecked @('push', $runPatchPath, '/data/local/tmp/mgpatch/run_patch.sh') | Out-Null

$patchOut = Invoke-AdbChecked @('shell', 'sh /data/local/tmp/mgpatch/run_patch.sh')
Write-Host $patchOut
if ($patchOut -notmatch 'init\.rg477m\.rc' -or $patchOut -notmatch 'rg477m_setup\.sh') {
    throw 'Headless overlay.d files were NOT injected into ramdisk.cpio!'
}

$outImg = Join-Path $buildDir ("init_boot{0}_magisk.img" -f $Slot)
if (Test-Path -LiteralPath $outImg) { Remove-Item -LiteralPath $outImg -Force }
Invoke-AdbChecked @('pull', '/data/local/tmp/mgpatch/new-boot.img', $outImg) | Out-Null
$null = Invoke-Adb -AdbExe $adb -AdbArgs @('shell', 'rm -rf /data/local/tmp/mgpatch')

if (-not (Test-Path -LiteralPath $outImg) -or (Get-Item -LiteralPath $outImg).Length -lt 1048576) {
    throw "Patched image missing or too small: $outImg"
}

$stockVbmeta = Join-Path $script:ProjectRoot ("backups\stock\vbmeta{0}.img" -f $Slot)
$outVbmeta   = Join-Path $buildDir ("vbmeta{0}_magisk.img" -f $Slot)
$patchAvbPs  = Join-Path $PSScriptRoot 'Patch-Avb.ps1'
& $patchAvbPs -InitBootMagisk $outImg -StockVbmeta $stockVbmeta -OutVbmeta $outVbmeta

$shaOut = (Get-FileHash -LiteralPath $outImg -Algorithm SHA256).Hash.ToLower()
$shaOut | Out-File -Encoding ascii "$outImg.sha256"
$shaVb = (Get-FileHash -LiteralPath $outVbmeta -Algorithm SHA256).Hash.ToLower()
$shaVb | Out-File -Encoding ascii "$outVbmeta.sha256"
Write-Host ("[ OK ] Headless Magisk images ready: {0} (sha256={1}) + {2} (sha256={3})" -f $outImg, $shaOut.Substring(0, 16), $outVbmeta, $shaVb.Substring(0, 16)) -ForegroundColor Green
