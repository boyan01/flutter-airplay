# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([switch]$SkipBuild, [string]$InnoCompiler)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $root
try {
    if (-not $InnoCompiler) {
        $candidates = @(
            $env:AIRPLAY_ISCC,
            (Join-Path $root 'windows/.cache/tools/inno-6.7.3/ISCC.exe'),
            "$env:ProgramFiles/Inno Setup 7/ISCC.exe",
            "${env:ProgramFiles(x86)}/Inno Setup 7/ISCC.exe",
            "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe"
        )
        $command = Get-Command ISCC -ErrorAction SilentlyContinue
        if ($command) { $candidates += $command.Source }
        foreach ($candidate in $candidates) {
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { $InnoCompiler = $candidate; break }
        }
    }
    if (-not $InnoCompiler -or -not (Test-Path -LiteralPath $InnoCompiler)) {
        throw 'Install Inno Setup 6.6+ (winget install --id JRSoftware.InnoSetup -e -s winget), or pass -InnoCompiler with ISCC.exe.'
    }
    $versionText = Get-Content pubspec.yaml -Raw
    if ($versionText -notmatch '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$') {
        throw 'pubspec.yaml must contain version: major.minor.patch+build.'
    }
    $appVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
    $fileVersion = "$appVersion.$($Matches[4])"
    if (-not $SkipBuild) {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows Release build failed.' }
    }
    $bundle = Join-Path $root 'build/windows/x64/runner/Release'
    $required = @('flutter_airplay.exe', 'flutter_windows.dll', 'airplay_player.dll',
        'cnativeapi.dll', 'data/app.so', 'data/icudtl.dat',
        'data/flutter_assets/AssetManifest.bin', 'data/licenses/LICENSE',
        'data/licenses/THIRD_PARTY_NOTICES.md', 'data/licenses/FFmpeg/FFmpeg-build-config.txt',
        'data/licenses/FFmpeg/COPYING.LGPLv2.1', 'data/licenses/FFmpeg/LICENSE.md')
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $bundle $name) -PathType Leaf)) { throw "Missing Release bundle file: $name" }
    }
    foreach ($component in @('avcodec', 'avutil', 'swresample', 'swscale')) {
        if (@(Get-ChildItem -LiteralPath $bundle -Filter "$component-*.dll").Count -ne 1) {
            throw "Missing or ambiguous FFmpeg runtime: $component"
        }
    }
    $info = (Get-Item (Join-Path $bundle 'flutter_airplay.exe')).VersionInfo
    $actual = "$($info.FileMajorPart).$($info.FileMinorPart).$($info.FileBuildPart).$($info.FilePrivatePart)"
    if ($actual -ne $fileVersion) { throw "Release version $actual does not match pubspec $fileVersion. Rebuild without -SkipBuild." }
    $output = Join-Path $root 'build/distribution/windows'
    $staging = Join-Path $output 'bundle'
    # Replace only this generated staging directory, after checking its boundary.
    $resolvedStaging = [IO.Path]::GetFullPath($staging)
    if ($resolvedStaging -ne [IO.Path]::GetFullPath((Join-Path $root 'build/distribution/windows/bundle'))) {
        throw 'Refusing to replace a staging directory outside the package output.'
    }
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $resolvedStaging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    Get-ChildItem -LiteralPath $bundle | Where-Object { $_.Name -ne 'windows_texture_test.exe' -and $_.Extension -notin @('.pdb', '.lib', '.exp') } |
        Copy-Item -Destination $staging -Recurse -Force
    $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
    $vsInstall = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsInstall) { throw 'Visual Studio 2022 C++ redistributable files are required.' }
    $redistRoot = Join-Path $vsInstall 'VC/Redist/MSVC'
    $redist = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $redist) { throw 'Missing x64 Microsoft.VC143.CRT redistributable directory.' }
    Get-ChildItem -LiteralPath $redist -Filter '*.dll' | Copy-Item -Destination $staging -Force
    foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $staging $name))) { throw "Missing VC++ runtime: $name" }
    }
    $artwork = Join-Path $output 'artwork'
    & (Join-Path $PSScriptRoot 'installer_artwork.ps1') -OutputDirectory $artwork
    & $InnoCompiler "/DBundleDir=$staging" "/DOutputDir=$output" "/DArtworkDir=$artwork" "/DAppVersion=$appVersion" "/DFileVersion=$fileVersion" (Join-Path $root 'windows/installer/flutter_airplay.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed; use Inno Setup 6.6 or newer.' }
    $setup = Join-Path $output "Flutter-AirPlay-$appVersion-windows-x64-setup.exe"
    if (-not (Test-Path -LiteralPath $setup)) { throw 'Inno Setup did not produce the expected installer.' }
    $hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($setup))" | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS') -Encoding ascii
    Write-Host "Installer: $setup"
} finally {
    Pop-Location
}
