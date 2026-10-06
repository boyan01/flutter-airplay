# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Installer)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$registration = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/{D8393B77-9CE5-4D58-8CAC-2BD0621E7C16}_is1'
if (Test-Path -LiteralPath $registration) { throw 'Installer smoke test requires no existing Flutter AirPlay installation.' }
if (Get-Process -Name flutter_airplay -ErrorAction SilentlyContinue) { throw 'Quit Flutter AirPlay before the installer smoke test.' }
$evidence = Join-Path $root 'artifacts/windows-installer-smoke'
$app = Join-Path $evidence 'app'
if (Test-Path -LiteralPath $app) { throw "Remove the previous smoke-test installation before retrying: $app" }
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$child = $null
$loginKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Run'
$loginRegistry = Get-Item -LiteralPath $loginKey -ErrorAction SilentlyContinue
$originalLogin = if ($loginRegistry) { $loginRegistry.GetValue('FlutterAirPlay', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
$originalLoginKind = if ($null -ne $originalLogin) { $loginRegistry.GetValueKind('FlutterAirPlay') } else { $null }
try {
    foreach ($language in @('english', 'chinesesimp')) {
        $arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS /LANG=$language /DIR=`"$app`" /LOG=`"$evidence/install-$language.log`""
        $process = Start-Process -FilePath $Installer -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Installer failed ($language), exit $($process.ExitCode). See $evidence." }
        $entry = Get-ItemProperty -LiteralPath $registration
        if ([IO.Path]::GetFullPath($entry.InstallLocation.TrimEnd('\')) -ne [IO.Path]::GetFullPath($app)) {
            throw 'Installer registered the wrong application directory.'
        }
        foreach ($name in @('flutter_airplay.exe', 'flutter_windows.dll', 'cnativeapi.dll',
            'airplay_player.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
            'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin',
            'data/licenses/FFmpeg/COPYING.LGPLv2.1', 'unins000.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $app $name))) { throw "Installed file missing: $name" }
        }
        # The second install exercises an in-place upgrade using the same AppId.
    }
    $child = Start-Process -FilePath (Join-Path $app 'flutter_airplay.exe') -WorkingDirectory $evidence -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 5
    if ($child.HasExited) { throw "Installed Release app exited during startup: $($child.ExitCode)" }
    Stop-Process -Id $child.Id -Force
    $child = $null
    New-Item -Path $loginKey -Force | Out-Null
    Set-ItemProperty -LiteralPath $loginKey -Name FlutterAirPlay -Value ('"' + (Join-Path $app 'flutter_airplay.exe') + '"')
    Write-Host 'PASS: English install, Chinese upgrade, payload and Release process startup'
} finally {
    if ($child -and -not $child.HasExited) { Stop-Process -Id $child.Id -Force }
    try {
        $uninstaller = Join-Path $app 'unins000.exe'
        if (Test-Path -LiteralPath $uninstaller) {
            $process = Start-Process -FilePath $uninstaller -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$evidence/uninstall.log`"" -WindowStyle Hidden -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "Uninstall failed, exit $($process.ExitCode). See $evidence." }
            if ((Test-Path -LiteralPath $registration) -or (Test-Path -LiteralPath (Join-Path $app 'flutter_airplay.exe'))) {
                throw 'Uninstall left the application or its registration behind.'
            }
            if ((Get-Item -LiteralPath $loginKey).GetValue('FlutterAirPlay', $null)) {
                throw 'Uninstall did not remove its login startup entry.'
            }
            Write-Host 'PASS: uninstall removed the application, registration and login startup entry'
        }
    } finally {
        # Startup can be enabled in the developer's existing receiver settings.
        # Restore their original entry even if launch or uninstall fails.
        if ($null -ne $originalLogin) {
            New-ItemProperty -Path $loginKey -Name FlutterAirPlay -Value $originalLogin -PropertyType $originalLoginKind -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $loginKey -Name FlutterAirPlay -ErrorAction SilentlyContinue
        }
    }
}
