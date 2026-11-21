param(
    [Parameter(Mandatory = $true)][string]$InitBootMagisk,
    [Parameter(Mandatory = $true)][string]$StockVbmeta,
    [Parameter(Mandatory = $true)][string]$OutVbmeta
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Numerics

$AOSP_TESTKEY_N_HEX = 'c65551dd3224a2e00ebc7efdbda2538058697ef54a4087959054593d55caff36341afae1e0902a1a32685bf3dfad0bf9b1d0f7eaab471f76be1b984b67a362fadfe6b5f8ee73165fb8b182de4989d53dd7a842998175c8d8847bbd54a8226444bc3406103c89c2d1f32c036591b1a0d1c82156159948202774ef017a76a50b6bfde3faed0df90f7a41fa76053749fe344f4b0149e498f7898ecd36aa391da97d5d6b5a52d17569a8df7cde1c1bf9d9195bb7474cb9702eade5d6887ced926e460810b576033e09ac4db62ccd1200bdd4a703d31b910823365b11feaf5969b33c8824372d61bac599511897f92342969f872ecdb24d5fa924f245dae26526264d'
$AOSP_TESTKEY_D_HEX = 'be90981a0ae5fcc18027497590d1f99d6655e730d469705d1ad290f4480cc66f545d6015cc6978aab72862c1ce773cfc6c08374d79c8dac8831d8c95573d3c0b853aee3a0312fdba7781c816c15df85075782c95c6386004fa36d2d216c304c8ae74e6268fa46656c869cfd1b5cd909240d3171da5ac118917e7d5e9cf3a01dfce2746e97642012dc3350d47d5e5a7382d2412e4dd200292fb0d990fc35bc2161d72e0f2f2e7d4bcd52767b7075e87e0ca04d93087c6a7cc82bd372034512688247a742e42c1617af613a3f989c874966af560ccc1c6f48e66f9e7a91785b2863d58e16c8a02e308fbd747017fe1ecbb7c5c50900a1e436e4546cc6af7e2c581'
$AOSP_TESTKEY_E = [System.Numerics.BigInteger]::new(65537)
$ASN1_SHA256_PREFIX_HEX = '3031300d060960864801650304020105000420'

function ConvertFrom-HexString {
    param([string]$Hex)
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    return ,$bytes
}

function ConvertFrom-BigEndianBytes {
    param([byte[]]$Bytes)
    $rev = New-Object byte[] ($Bytes.Length + 1)
    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        $rev[$i] = $Bytes[$Bytes.Length - 1 - $i]
    }
    $rev[$Bytes.Length] = 0
    return (New-Object System.Numerics.BigInteger -ArgumentList @(,$rev))
}

function ConvertTo-BigEndianBytes {
    param(
        [System.Numerics.BigInteger]$Value,
        [int]$Length = 256
    )
    $le = $Value.ToByteArray()
    $out = New-Object byte[] $Length
    $copyLen = [Math]::Min($le.Length, $Length)
    for ($i = 0; $i -lt $copyLen; $i++) {
        $out[$Length - 1 - $i] = $le[$i]
    }
    return ,$out
}

function Read-UInt32BE {
    param([byte[]]$Buf, [int]$Off)
    return (([uint32]$Buf[$Off] -shl 24) -bor ([uint32]$Buf[$Off + 1] -shl 16) -bor ([uint32]$Buf[$Off + 2] -shl 8) -bor [uint32]$Buf[$Off + 3])
}

function Read-UInt64BE {
    param([byte[]]$Buf, [int]$Off)
    $hi = [uint64](Read-UInt32BE $Buf $Off)
    $lo = [uint64](Read-UInt32BE $Buf ($Off + 4))
    return (($hi -shl 32) -bor $lo)
}

function Write-UInt64BE {
    param([byte[]]$Buf, [int]$Off, [uint64]$Val)
    for ($i = 0; $i -lt 8; $i++) {
        $Buf[$Off + $i] = [byte](($Val -shr (56 - 8 * $i)) -band 0xff)
    }
}

function Get-Sha256Concat {
    param([byte[]]$PartA, [int]$OffsetA, [int]$CountA, [byte[]]$PartB, [int]$OffsetB, [int]$CountB)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        if ($CountA -gt 0) {
            [void]$sha.TransformBlock($PartA, $OffsetA, $CountA, $null, 0)
        }
        [void]$sha.TransformFinalBlock($PartB, $OffsetB, $CountB)
        return ,$sha.Hash
    } finally {
        $sha.Dispose()
    }
}

function Invoke-Rsa2048Pkcs1V15Sign {
    param([byte[]]$Digest32)
    if ($Digest32.Length -ne 32) { throw "Expected 32-byte digest, got $($Digest32.Length)" }
    $prefix = ConvertFrom-HexString $ASN1_SHA256_PREFIX_HEX
    $padLen = 256 - 3 - $prefix.Length - 32
    $em = New-Object byte[] 256
    $em[0] = 0x00
    $em[1] = 0x01
    for ($i = 0; $i -lt $padLen; $i++) { $em[2 + $i] = 0xff }
    $em[2 + $padLen] = 0x00
    [Array]::Copy($prefix, 0, $em, 3 + $padLen, $prefix.Length)
    [Array]::Copy($Digest32, 0, $em, 3 + $padLen + $prefix.Length, 32)

    $mInt = ConvertFrom-BigEndianBytes $em
    $dInt = ConvertFrom-BigEndianBytes (ConvertFrom-HexString $AOSP_TESTKEY_D_HEX)
    $nInt = ConvertFrom-BigEndianBytes (ConvertFrom-HexString $AOSP_TESTKEY_N_HEX)
    $sigInt = [System.Numerics.BigInteger]::ModPow($mInt, $dInt, $nInt)
    return ,(ConvertTo-BigEndianBytes -Value $sigInt -Length 256)
}

function Test-Rsa2048Pkcs1V15Verify {
    param([byte[]]$Sig256, [byte[]]$Digest32, [System.Numerics.BigInteger]$PubN)
    $prefix = ConvertFrom-HexString $ASN1_SHA256_PREFIX_HEX
    $padLen = 256 - 3 - $prefix.Length - 32
    $expected = New-Object byte[] 256
    $expected[0] = 0x00
    $expected[1] = 0x01
    for ($i = 0; $i -lt $padLen; $i++) { $expected[2 + $i] = 0xff }
    $expected[2 + $padLen] = 0x00
    [Array]::Copy($prefix, 0, $expected, 3 + $padLen, $prefix.Length)
    [Array]::Copy($Digest32, 0, $expected, 3 + $padLen + $prefix.Length, 32)

    $sInt = ConvertFrom-BigEndianBytes $Sig256
    $decInt = [System.Numerics.BigInteger]::ModPow($sInt, $AOSP_TESTKEY_E, $PubN)
    $dec = ConvertTo-BigEndianBytes -Value $decInt -Length 256
    for ($i = 0; $i -lt 256; $i++) {
        if ($dec[$i] -ne $expected[$i]) { return $false }
    }
    return $true
}

function Patch-HashDescriptorInAux {
    param(
        [byte[]]$Aux,
        [int]$DescOff,
        [int]$DescSz,
        [string]$TargetPart,
        [uint64]$NewImgSz,
        [byte[]]$NewDigest
    )
    $pos = $DescOff
    $end = $DescOff + $DescSz
    while ($pos + 16 -le $end) {
        $tag = Read-UInt64BE $Aux $pos
        $nbytes = [int](Read-UInt64BE $Aux ($pos + 8))
        $bodyStart = $pos + 16
        if ($tag -eq 2) {
            $pnLen  = [int](Read-UInt32BE $Aux ($bodyStart + 40))
            $saltLen = [int](Read-UInt32BE $Aux ($bodyStart + 44))
            $digLen  = [int](Read-UInt32BE $Aux ($bodyStart + 48))
            $off = $bodyStart + 116
            $pn = [System.Text.Encoding]::UTF8.GetString($Aux, $off, $pnLen)
            if ($pn -eq $TargetPart) {
                $salt = New-Object byte[] $saltLen
                [Array]::Copy($Aux, $off + $pnLen, $salt, 0, $saltLen)
                if ($null -ne $NewDigest) {
                    Write-UInt64BE $Aux $bodyStart $NewImgSz
                    [Array]::Copy($NewDigest, 0, $Aux, $off + $pnLen + $saltLen, $digLen)
                }
                $curDig = New-Object byte[] $digLen
                [Array]::Copy($Aux, $off + $pnLen + $saltLen, $curDig, 0, $digLen)
                return @{ Salt = $salt; Digest = $curDig }
            }
        }
        $pos += 16 + $nbytes
    }
    throw "AvbHashDescriptor for '$TargetPart' not found"
}

$ib = [System.IO.File]::ReadAllBytes($InitBootMagisk)
$vb = [System.IO.File]::ReadAllBytes($StockVbmeta)

if ($ib.Length -lt 64) { throw "Image too small for AVBf footer: $InitBootMagisk" }
$footerOff = $ib.Length - 64
$magic = [System.Text.Encoding]::ASCII.GetString($ib, $footerOff, 4)
if ($magic -ne 'AVBf') { throw "Missing AVBf footer in $InitBootMagisk" }
$origSz = Read-UInt64BE $ib ($footerOff + 12)
$vbOff  = [int](Read-UInt64BE $ib ($footerOff + 20))
$vbSz   = [int](Read-UInt64BE $ib ($footerOff + 28))

$vbHdr = New-Object byte[] 256
[Array]::Copy($vb, 0, $vbHdr, 0, 256)
$authSz  = [int](Read-UInt64BE $vbHdr 12)
$auxSz   = [int](Read-UInt64BE $vbHdr 20)
$hashOff = [int](Read-UInt64BE $vbHdr 32)
$hashSz  = [int](Read-UInt64BE $vbHdr 40)
$sigOff  = [int](Read-UInt64BE $vbHdr 48)
$sigSz   = [int](Read-UInt64BE $vbHdr 56)
$pkOff   = [int](Read-UInt64BE $vbHdr 64)
$pkSz    = [int](Read-UInt64BE $vbHdr 72)
$descOff = [int](Read-UInt64BE $vbHdr 96)
$descSz  = [int](Read-UInt64BE $vbHdr 104)

$vbAux = New-Object byte[] $auxSz
[Array]::Copy($vb, 256 + $authSz, $vbAux, 0, $auxSz)
$descInfo = Patch-HashDescriptorInAux -Aux $vbAux -DescOff $descOff -DescSz $descSz -TargetPart 'init_boot' -NewImgSz $origSz -NewDigest $null
$salt = $descInfo.Salt

$newDigest = Get-Sha256Concat -PartA $salt -OffsetA 0 -CountA $salt.Length -PartB $ib -OffsetB 0 -CountB ([int]$origSz)

# Update internal AVB0 inside init_boot_magisk
$ibVb = New-Object byte[] $vbSz
[Array]::Copy($ib, $vbOff, $ibVb, 0, $vbSz)
$ibAuthSz  = [int](Read-UInt64BE $ibVb 12)
$ibAuxSz   = [int](Read-UInt64BE $ibVb 20)
$ibDescOff = [int](Read-UInt64BE $ibVb 96)
$ibDescSz  = [int](Read-UInt64BE $ibVb 104)
$ibAux = New-Object byte[] $ibAuxSz
[Array]::Copy($ibVb, 256 + $ibAuthSz, $ibAux, 0, $ibAuxSz)
[void](Patch-HashDescriptorInAux -Aux $ibAux -DescOff $ibDescOff -DescSz $ibDescSz -TargetPart 'init_boot' -NewImgSz $origSz -NewDigest $newDigest)
[Array]::Copy($ibAux, 0, $ibVb, 256 + $ibAuthSz, $ibAuxSz)
[Array]::Copy($ibVb, 0, $ib, $vbOff, $vbSz)
[System.IO.File]::WriteAllBytes($InitBootMagisk, $ib)

# Update stock vbmeta aux & re-sign
[void](Patch-HashDescriptorInAux -Aux $vbAux -DescOff $descOff -DescSz $descSz -TargetPart 'init_boot' -NewImgSz $origSz -NewDigest $newDigest)
$vbDigest = Get-Sha256Concat -PartA $vbHdr -OffsetA 0 -CountA $vbHdr.Length -PartB $vbAux -OffsetB 0 -CountB $vbAux.Length
$vbSig = Invoke-Rsa2048Pkcs1V15Sign -Digest32 $vbDigest

$vbAuth = New-Object byte[] $authSz
[Array]::Copy($vb, 256, $vbAuth, 0, $authSz)
[Array]::Copy($vbDigest, 0, $vbAuth, $hashOff, $hashSz)
[Array]::Copy($vbSig, 0, $vbAuth, $sigOff, $sigSz)

[Array]::Copy($vbAuth, 0, $vb, 256, $authSz)
[Array]::Copy($vbAux, 0, $vb, 256 + $authSz, $auxSz)

$pubBytes = New-Object byte[] 256
[Array]::Copy($vbAux, $pkOff + 8, $pubBytes, 0, 256)
$pubN = ConvertFrom-BigEndianBytes $pubBytes
if (-not (Test-Rsa2048Pkcs1V15Verify -Sig256 $vbSig -Digest32 $vbDigest -PubN $pubN)) {
    throw 'RSA-2048 self-verification failed on patched vbmeta!'
}

[System.IO.File]::WriteAllBytes($OutVbmeta, $vb)

$digHex = ([System.BitConverter]::ToString($newDigest)).Replace('-', '').ToLower().Substring(0, 16)
$sigHex = ([System.BitConverter]::ToString($vbSig)).Replace('-', '').ToLower().Substring(0, 16)
Write-Host ("[ OK ] AVB patched & verified (.NET): init_boot orig_sz=0x{0:x}, digest={1}..., vbmeta_sig={2}..." -f $origSz, $digHex, $sigHex)
