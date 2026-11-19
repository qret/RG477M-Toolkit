# _common.ps1 - Shared portable helpers for RG477M Toolkit

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:LocalPathsFile = Join-Path $script:ProjectRoot 'local.paths.json'
$script:LocalCfg = $null
if (Test-Path -LiteralPath $script:LocalPathsFile) {
    $script:LocalCfg = Get-Content -LiteralPath $script:LocalPathsFile -Raw | ConvertFrom-Json
}

function Resolve-ToolPath {
    param(
        [string]$ExplicitPath,
        [string]$EnvVarName,
        [string]$LocalCfgKey,
        [string[]]$RelativeCandidates,
        [string]$CommandName
    )
    if ($ExplicitPath -and (Test-Path -LiteralPath $ExplicitPath)) { return (Resolve-Path -LiteralPath $ExplicitPath).Path }
    if ($EnvVarName) {
        $ev = [Environment]::GetEnvironmentVariable($EnvVarName)
        if ($ev -and (Test-Path -LiteralPath $ev)) { return (Resolve-Path -LiteralPath $ev).Path }
    }
    if ($script:LocalCfg -and $LocalCfgKey) {
        $lv = $script:LocalCfg.$LocalCfgKey
        if ($lv -and (Test-Path -LiteralPath $lv)) { return (Resolve-Path -LiteralPath $lv).Path }
    }
    foreach ($rel in $RelativeCandidates) {
        $cand = Join-Path $script:ProjectRoot $rel
        if (Test-Path -LiteralPath $cand) { return (Resolve-Path -LiteralPath $cand).Path }
    }
    if ($CommandName) {
        $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Get-AdbPath {
    param([string]$ExplicitPath = '')
    $p = Resolve-ToolPath -ExplicitPath $ExplicitPath -EnvVarName 'RG477M_ADB' -LocalCfgKey 'adb' -RelativeCandidates @('runtime\adb\adb.exe', 'tools\adb-fastboot\adb.exe') -CommandName 'adb'
    if (-not $p -and $env:ANDROID_HOME) {
        $sdkAdb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
        if (Test-Path -LiteralPath $sdkAdb) { return $sdkAdb }
    }
    return $p
}

function Get-SpftExe {
    param([string]$ExplicitDir = '')
    if ($ExplicitDir) {
        $exe = Join-Path $ExplicitDir 'SPFlashToolV6.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    $dir = Resolve-ToolPath -EnvVarName 'RG477M_SPFT' -LocalCfgKey 'spft_dir' -RelativeCandidates @('runtime\spflashtool', 'tools\spflashtool\v6.2404', 'tools\spflashtool')
    if ($dir) {
        $exe = Join-Path $dir 'SPFlashToolV6.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function Get-DaDir {
    param([string]$ExplicitDir = '')
    return Resolve-ToolPath -ExplicitPath $ExplicitDir -EnvVarName 'RG477M_DA_DIR' -LocalCfgKey 'da_dir' -RelativeCandidates @('runtime\rg477m_da', 'tools\spflashtool\rg477m_da', 'assets\rg477m_da')
}

function Get-SpftLogDir {
    if ($script:LocalCfg -and $script:LocalCfg.log_dir) { return $script:LocalCfg.log_dir }
    return (Join-Path $script:ProjectRoot 'logs\sp_ft')
}

function Invoke-SpftConfig {
    param(
        [string]$SpftExe,
        [string]$ConfigPath
    )
    $outLog = Join-Path $script:ProjectRoot 'build\spft_stdout.log'
    $errLog = Join-Path $script:ProjectRoot 'build\spft_stderr.log'
    Remove-Item -LiteralPath $outLog, $errLog -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $SpftExe -ArgumentList @('-r', '-i', "`"$ConfigPath`"") -NoNewWindow -PassThru -Wait -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $allText = ''
    if (Test-Path -LiteralPath $outLog) {
        $t = Get-Content -LiteralPath $outLog -Raw -ErrorAction SilentlyContinue
        if ($t) { Write-Host $t; $allText += $t }
    }
    if (Test-Path -LiteralPath $errLog) {
        $t = Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue
        if ($t) { Write-Host $t; $allText += "`n$t" }
    }
    if ($allText -match 'execute failed|failed,|BaseException|XML Schema validation failed') { return 2 }
    if ($allText -notmatch 'All command exec done!') { return 3 }
    if ($null -ne $p.ExitCode -and $p.ExitCode -ne 0) { return [int]$p.ExitCode }
    return 0
}

function Invoke-Adb {
    param([string]$AdbExe, [string[]]$AdbArgs)
    $ep = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $AdbExe @AdbArgs 2>&1 | Where-Object { $_ -notmatch '^\* daemon ' } | Out-String).Trim()
        return $out
    } finally {
        $ErrorActionPreference = $ep
    }
}

function Assert-DeviceGuard {
    param([string]$AdbExe)
    $guardPath = Join-Path $script:ProjectRoot 'config\devices\rg477m-mt6897\guard.json'
    $guard = Get-Content -LiteralPath $guardPath -Raw | ConvertFrom-Json
    $state = Invoke-Adb -AdbExe $AdbExe -AdbArgs @('get-state')
    if ($LASTEXITCODE -ne 0 -or $state -ne 'device') {
        throw "ADB device not ready (state='$state'). Connect RG477M with USB debugging enabled."
    }
    foreach ($prop in $guard.match.PSObject.Properties) {
        $got = Invoke-Adb -AdbExe $AdbExe -AdbArgs @('shell', 'getprop', $prop.Name)
        if ($got -ne $prop.Value) {
            throw "Guard mismatch: $($prop.Name)='$got' (expected '$($prop.Value)'). Aborting!"
        }
    }
    $buildId = Invoke-Adb -AdbExe $AdbExe -AdbArgs @('shell', 'getprop', 'ro.build.display.id')
    if ($guard.supported_builds -and ($guard.supported_builds -notcontains $buildId)) {
        throw "Unsupported firmware: '$buildId' (supported: $($guard.supported_builds -join ', ')). Program blocked!"
    }
    $slot = Invoke-Adb -AdbExe $AdbExe -AdbArgs @('shell', 'getprop', 'ro.boot.slot_suffix')
    $dfOut = Invoke-Adb -AdbExe $AdbExe -AdbArgs @('shell', 'df', '-B1', '/data')
    $storageGB = 256
    if ($dfOut -match '\s(\d+)\s+\d+\s+\d+\s+\d+%') {
        $bytes = [double]$Matches[1]
        if ($bytes -lt 150000000000) { $storageGB = 128 } else { $storageGB = 256 }
    }
    $stateObj = [PSCustomObject]@{
        Model     = 'RG477M'
        BuildId   = $buildId
        Slot      = $slot
        StorageGB = $storageGB
    }
    $stateFile = Join-Path $script:ProjectRoot 'backups\stock\device_state.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
    $stateObj | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
    return $stateObj
}

function Resolve-DeviceSlotAndStorage {
    param([string]$ExplicitSlot = '', [int]$ExplicitStorageGB = 0)
    $slot = $ExplicitSlot
    $storage = $ExplicitStorageGB
    $adb = Get-AdbPath
    if ($adb) {
        $st = Invoke-Adb -AdbExe $adb -AdbArgs @('get-state')
        if ($st -eq 'device') {
            $info = Assert-DeviceGuard -AdbExe $adb
            if (-not $slot) { $slot = $info.Slot }
            if ($storage -eq 0) { $storage = $info.StorageGB }
        }
    }
    $stateFile = Join-Path $script:ProjectRoot 'backups\stock\device_state.json'
    if ((Test-Path -LiteralPath $stateFile) -and (-not $slot -or $storage -eq 0)) {
        $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if (-not $slot) { $slot = $saved.Slot }
        if ($storage -eq 0) { $storage = [int]$saved.StorageGB }
    }
    if (-not $slot) { $slot = '_b' }
    if ($storage -eq 0) { $storage = 256 }
    return [PSCustomObject]@{ Slot = $slot; StorageGB = $storage }
}
