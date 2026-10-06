# SPDX-License-Identifier: GPL-3.0-only
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
