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
