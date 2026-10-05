# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([switch]$Tests, [string]$Bash, [string]$Make)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $IsWindows -and $env:OS -ne 'Windows_NT') { throw 'The native Windows build requires a Windows host.' }
if ($env:VSCMD_ARG_TGT_ARCH -ne 'x64' -or
    -not (Get-Command nmake -ErrorAction SilentlyContinue) -or
    -not (Get-Command clang-cl -ErrorAction SilentlyContinue)) {
    $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw 'Install Visual Studio 2022 with C++ Desktop Development and Clang tools. See DEVELOPMENT.md.' }
    $vsInstall = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsInstall) { throw 'Visual Studio 2022 C++ tools are unavailable. See DEVELOPMENT.md.' }
    $env:VSINSTALLDIR = "$vsInstall\"
    & "$vsInstall/Common7/Tools/Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
}
if (-not $Bash) { $Bash = $env:AIRPLAY_BASH }
if (-not $Make) { $Make = $env:AIRPLAY_MAKE }
foreach ($tool in @('git', 'cmake', 'perl', 'nmake', 'clang-cl')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing $tool. Use a Visual Studio x64 Native Tools prompt with the C++ Clang tools component installed." }
}
if (-not $Bash) {
    if (Test-Path 'C:/msys64/usr/bin/bash.exe') { $Bash = 'C:/msys64/usr/bin/bash.exe' }
    else {
        $gitDirectory = Split-Path (Get-Command git).Source
        $Bash = Join-Path $gitDirectory '../bin/bash.exe'
    }
}
if (-not (Test-Path $Bash)) { throw 'Git Bash is required. Pass -Bash with a bash.exe path if using MSYS2.' }
# A script file preserves shell quoting under both Windows PowerShell 5 and pwsh.
$probeDirectory = Join-Path $root 'build/native-preparation'
New-Item -ItemType Directory -Force $probeDirectory | Out-Null
$makeProbe = Join-Path $probeDirectory 'check_make.sh'
[IO.File]::WriteAllText($makeProbe, '"$1" --version' + "`n", (New-Object Text.UTF8Encoding($false)))
if (-not $Make) {
    $candidates = @(
        (Join-Path (Split-Path $Bash) 'make.exe'),
        (Join-Path (Split-Path $Bash) '../usr/bin/make.exe')
    )
    foreach ($name in @('make', 'gmake')) {
        $candidates += @(Get-Command $name -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $version = @(& $Bash --noprofile --norc $makeProbe $candidate 2>&1)
            if ($LASTEXITCODE -eq 0 -and ($version -join "`n") -match 'GNU Make' -and
                ($version -join "`n") -match 'Built for .*-(msys|cygwin)') {
                $Make = (Resolve-Path -LiteralPath $candidate).Path
                break
            }
        } catch { continue }
    }
}
if (-not $Make) {
    $downloadedMake = & python (Join-Path $root 'scripts/ensure_native.py') windows --prepare-windows-make
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the pinned Windows GNU Make tool.' }
    $Make = ($downloadedMake | Select-Object -Last 1).Trim()
}
$makeVersion = @(& $Bash --noprofile --norc $makeProbe $Make)
if ($LASTEXITCODE -ne 0 -or ($makeVersion -join "`n") -notmatch 'GNU Make' -or
    ($makeVersion -join "`n") -notmatch 'Built for .*-(msys|cygwin)') {
    throw "FFmpeg requires MSYS2/Cygwin GNU Make; selected: $Make. Install MSYS2 make (pacman -S make), or set AIRPLAY_MAKE to its make.exe path. Native Windows make is incompatible."
}
Write-Host "Windows build tools: Bash=$Bash Make=$Make"
$lock = Get-Content (Join-Path $root 'android/dependencies.lock.json') -Raw | ConvertFrom-Json
& python (Join-Path $root 'scripts/ensure_native.py') windows --prepare-dependencies
if ($LASTEXITCODE -ne 0) { throw 'Could not prepare native dependency cache.' }
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
$ffmpeg = Get-PinnedSource $lock.ffmpeg 'ffmpeg'
$ffmpegReady = Test-Path (Join-Path $cache 'ffmpeg-aac/licenses/FFmpeg-build-config.txt')
foreach ($component in @('avcodec', 'avutil', 'swresample', 'swscale')) {
    $ffmpegReady = $ffmpegReady -and (Test-Path (Join-Path $cache "ffmpeg-aac/bin/$component.lib")) -and
        (@(Get-ChildItem (Join-Path $cache "ffmpeg-aac/bin/$component-*.dll") -ErrorAction SilentlyContinue).Count -eq 1)
}
if (-not $ffmpegReady) {
    Invoke-Checked { & $Bash --noprofile --norc (Join-Path $PSScriptRoot 'build_ffmpeg.sh') `
        $ffmpeg (Join-Path $cache 'ffmpeg-build') (Join-Path $cache 'ffmpeg-aac') $Make }
}
$crypto = Join-Path $cache 'crypto'
$opensslBuild = Join-Path $cache 'openssl-build'
New-Item -ItemType Directory -Force $opensslBuild | Out-Null
if (-not (Test-Path (Join-Path $crypto 'lib/libcrypto.lib')) -or
    -not (Test-Path (Join-Path $crypto 'include/openssl/crypto.h'))) {
Push-Location $opensslBuild
try {
    # Compile source only, without assembly tools or external codec binaries.
    Invoke-Checked { perl (Join-Path $openssl 'Configure') VC-WIN64A no-shared no-tests no-apps no-docs no-module no-dso no-asm "--prefix=$crypto" '--libdir=lib' }
    Invoke-Checked { nmake }
    Invoke-Checked { nmake install_sw }
} finally { Pop-Location }
}
$native = Join-Path $root 'build/windows-native'
Push-Location $root
try {
    Invoke-Checked { cmake -S native -B $native -G 'Visual Studio 17 2022' -A x64 -T ClangCL `
        "-DUXPLAY_SOURCE=$($root.Replace('\', '/'))/vendor/UxPlay" `
        "-DPLIST_SOURCE=$($plist.Replace('\', '/'))" `
        "-DCRYPTO_PREFIX=$($crypto.Replace('\', '/'))" `
        "-DDEPS_SOURCE=$($cache.Replace('\', '/'))" `
        "-DFFMPEG_PREFIX=$($cache.Replace('\', '/'))/ffmpeg-aac" `
        "-DAIRPLAY_WINDOWS_BUILD_TESTS=$($Tests.IsPresent)" }
    Invoke-Checked { cmake --build $native --config Release --parallel }
    # Repair deleted runtime files even when the player itself needs no relink.
    Copy-Item (Join-Path $cache 'ffmpeg-aac/bin/*.dll') (Join-Path $native 'Release') -Force
    New-Item -ItemType Directory -Force (Join-Path $native 'Release/ffmpeg-licenses') | Out-Null
    Copy-Item (Join-Path $cache 'ffmpeg-aac/licenses/*') (Join-Path $native 'Release/ffmpeg-licenses') -Force
} finally { Pop-Location }
Write-Host 'Windows native player built. Run the latest Flutter stable SDK: flutter run -d windows. See DEVELOPMENT.md for setup, tests and packaging.'
if ($Tests) { Write-Host 'Native fixtures built. Run them with: bash scripts/test_native.sh windows' }
