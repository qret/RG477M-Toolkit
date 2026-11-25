param(
    [string]$OutZip = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\_common.ps1')

$versionPropsPath = Join-Path $script:ProjectRoot 'version.properties'
$appVersion = '0.1.0'
if (Test-Path -LiteralPath $versionPropsPath) {
    foreach ($line in (Get-Content -LiteralPath $versionPropsPath)) {
        if ($line -match '^\s*APP_VERSION\s*=\s*(.+)$') {
            $appVersion = $Matches[1].Trim()
        }
    }
}

$moduleDir = Join-Path $script:ProjectRoot 'magisk\module'
$extModuleDir = Get-StockFixModuleDir
if ($extModuleDir) {
    $srcResolved = (Resolve-Path -LiteralPath $extModuleDir).Path.TrimEnd('\', '/')
    $dstResolved = if (Test-Path -LiteralPath $moduleDir) { (Resolve-Path -LiteralPath $moduleDir).Path.TrimEnd('\', '/') } else { $moduleDir.TrimEnd('\', '/') }
    if ($srcResolved -ne $dstResolved) {
        New-Item -ItemType Directory -Force -Path $moduleDir | Out-Null
        $srcFiles = @(Get-ChildItem -LiteralPath $srcResolved -Recurse -File)
        $srcRelSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($sf in $srcFiles) {
            $rel = $sf.FullName.Substring($srcResolved.Length).TrimStart('\', '/')
            $null = $srcRelSet.Add($rel)
            $dstFile = Join-Path $moduleDir $rel
            $dstParent = Split-Path -Parent $dstFile
            if (-not (Test-Path -LiteralPath $dstParent)) {
                New-Item -ItemType Directory -Force -Path $dstParent | Out-Null
            }
            $needCopy = $true
            if (Test-Path -LiteralPath $dstFile) {
                $h1 = (Get-FileHash -LiteralPath $sf.FullName -Algorithm SHA256).Hash
                $h2 = (Get-FileHash -LiteralPath $dstFile -Algorithm SHA256).Hash
                if ($h1 -eq $h2) { $needCopy = $false }
            }
            if ($needCopy) {
                Copy-Item -LiteralPath $sf.FullName -Destination $dstFile -Force
            }
        }
        $dstFiles = @(Get-ChildItem -LiteralPath $moduleDir -Recurse -File)
        foreach ($df in $dstFiles) {
            $rel = $df.FullName.Substring($dstResolved.Length).TrimStart('\', '/')
            if (-not $srcRelSet.Contains($rel)) {
                Remove-Item -LiteralPath $df.FullName -Force
            }
        }
        $dstDirs = @(Get-ChildItem -LiteralPath $moduleDir -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($dd in $dstDirs) {
            if ((Get-ChildItem -LiteralPath $dd.FullName -Force | Measure-Object).Count -eq 0) {
                Remove-Item -LiteralPath $dd.FullName -Force
            }
        }
        Write-Host "[ OK ] Синхронизирован актуальный модуль из RG477M-StockFix ($($srcFiles.Count) файлов)" -ForegroundColor Cyan
    }
}
if (-not (Test-Path -LiteralPath $moduleDir)) {
    throw "Module source directory not found: $moduleDir"
}

$buildDir = Join-Path $script:ProjectRoot 'build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

if (-not $OutZip) {
    $OutZip = Join-Path $buildDir ("rg477m-perf-module-v{0}.zip" -f $appVersion)
}
if (Test-Path -LiteralPath $OutZip) {
    Remove-Item -LiteralPath $OutZip -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$files = Get-ChildItem -LiteralPath $moduleDir -Recurse -File | Sort-Object FullName
$stream = [System.IO.File]::Open($OutZip, [System.IO.FileMode]::Create)
try {
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($moduleDir.Length).TrimStart('\', '/').Replace('\', '/')
            $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $rawBytes = [System.IO.File]::ReadAllBytes($f.FullName)
                # Принудительно нормализуем LF для Android shell-скриптов и .prop
                $text = [System.Text.Encoding]::UTF8.GetString($rawBytes).Replace("`r`n", "`n")
                $lfBytes = ([System.Text.UTF8Encoding]::new($false)).GetBytes($text)
                $entryStream.Write($lfBytes, 0, $lfBytes.Length)
            } finally {
                $entryStream.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
} finally {
    $stream.Dispose()
}

$hash = (Get-FileHash -LiteralPath $OutZip -Algorithm SHA256).Hash.ToLowerInvariant()
$shaFile = "$OutZip.sha256"
Set-Content -LiteralPath $shaFile -Value "$hash  $([System.IO.Path]::GetFileName($OutZip))" -Encoding ASCII

Write-Host "[ OK ] Модуль собран: $OutZip ($($files.Count) файлов)" -ForegroundColor Green
Write-Host "[ OK ] SHA-256: $hash" -ForegroundColor Cyan
