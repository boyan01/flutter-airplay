# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([switch]$Tests)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $IsWindows -and $env:OS -ne 'Windows_NT') { throw 'The native Windows build requires a Windows host.' }
foreach ($tool in @('git', 'cmake', 'perl', 'nmake', 'clang-cl')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing $tool. Use a Visual Studio x64 Native Tools prompt with the C++ Clang tools component installed." }
}
$lock = Get-Content (Join-Path $root 'android/dependencies.lock.json') -Raw | ConvertFrom-Json
$cache = Join-Path $root 'build/windows-deps'
New-Item -ItemType Directory -Force $cache | Out-Null
function Invoke-Checked([scriptblock]$Command) {
    & $Command | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code $LASTEXITCODE" }
}
function Get-PinnedSource($entry, [string]$name) {
    $path = Join-Path $cache $name
    if (-not (Test-Path (Join-Path $path '.git'))) {
        Invoke-Checked { git init $path }
        Invoke-Checked { git -C $path remote add origin $entry.repository }
    }
    $dirty = & git -C $path status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect $name source cache" }
    if ($dirty) { throw "$name source cache has local changes; preserve or remove them before building." }
    $actual = $null
    $headFile = Join-Path $path '.git/HEAD'
    $headText = (Get-Content $headFile -Raw).Trim()
    if ($headText -match '^[0-9a-fA-F]{40}$') { $actual = $headText }
    elseif ($headText.StartsWith('ref: ')) {
        $reference = $headText.Substring(5)
        $referenceFile = Join-Path (Join-Path $path '.git') $reference
        if (Test-Path $referenceFile) { $actual = (Get-Content $referenceFile -Raw).Trim() }
        elseif (Test-Path (Join-Path $path '.git/packed-refs')) {
            $packed = Get-Content (Join-Path $path '.git/packed-refs') | Where-Object { $_ -match ('^[0-9a-fA-F]{40} ' + [regex]::Escape($reference) + '$') }
            if ($packed) { $actual = $packed.Substring(0, 40) }
        }
    }
    if ($actual -ne $entry.commit) {
        Invoke-Checked { git -C $path fetch --depth 1 origin $entry.commit }
        Invoke-Checked { git -C $path checkout --detach $entry.commit }
    }
    $actual = & git -C $path rev-parse HEAD
    if ($actual -ne $entry.commit) { throw "$name source commit differs from dependencies.lock.json" }
    return $path
}
$openssl = Get-PinnedSource $lock.openssl 'openssl'
$plist = Get-PinnedSource $lock.libplist 'libplist'
$crypto = Join-Path $cache 'crypto'
$opensslBuild = Join-Path $cache 'openssl-build'
New-Item -ItemType Directory -Force $opensslBuild | Out-Null
Push-Location $opensslBuild
try {
    # Compile source only, without assembly tools or external codec binaries.
    Invoke-Checked { perl (Join-Path $openssl 'Configure') VC-WIN64A no-shared no-tests no-apps no-docs no-module no-dso no-asm "--prefix=$crypto" '--libdir=lib' }
    Invoke-Checked { nmake }
    Invoke-Checked { nmake install_sw }
} finally { Pop-Location }
$native = Join-Path $root 'build/windows-native'
Push-Location $root
try {
    Invoke-Checked { cmake -S native -B $native -G 'Visual Studio 17 2022' -A x64 -T ClangCL "-DUXPLAY_SOURCE=$root/vendor/UxPlay" "-DPLIST_SOURCE=$plist" "-DCRYPTO_PREFIX=$crypto" "-DDEPS_SOURCE=$cache" "-DAIRPLAY_WINDOWS_BUILD_TESTS=$($Tests.IsPresent)" }
    Invoke-Checked { cmake --build $native --config Release --parallel }
    if ($Tests) { Invoke-Checked { ctest --test-dir $native -C Release --output-on-failure } }
} finally { Pop-Location }
Write-Host 'Windows native player built. Run the pinned Flutter SDK: flutter pub get; flutter build windows --release.'
