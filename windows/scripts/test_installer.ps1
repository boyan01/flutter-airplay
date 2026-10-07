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
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AirPlayWindowFixture {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern IntPtr FindWindowW(string className, string title);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
}
'@
function Read-RegistryValue([string]$Path) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($key) { return ,($key.GetValue('FlutterAirPlay', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) }
    return $null
}
function Start-App([string[]]$AppArguments = @()) {
    $options = @{ FilePath = (Join-Path $app 'flutter_airplay.exe'); WorkingDirectory = $evidence; WindowStyle = 'Hidden'; PassThru = $true }
    if ($AppArguments.Count) { $options.ArgumentList = $AppArguments }
    $script:child = Start-Process @options
}
function Stop-App {
    if ($script:child -and -not $script:child.HasExited) {
        Stop-Process -Id $script:child.Id -Force
        if (-not $script:child.WaitForExit(10000)) { throw 'Application did not stop.' }
    }
    $script:child = $null
}
function Wait-AppWindow {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $script:child.Refresh()
        if ($script:child.HasExited) { throw "Installed Release app exited during startup: $($script:child.ExitCode)" }
        $window = [AirPlayWindowFixture]::FindWindowW('FLUTTER_RUNNER_WIN32_WINDOW', 'Flutter AirPlay')
        if ($window -ne [IntPtr]::Zero) {
            [uint32]$owner = 0
            [AirPlayWindowFixture]::GetWindowThreadProcessId($window, [ref]$owner) | Out-Null
            if ($owner -eq $script:child.Id) { return $window }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The installed app did not create its window.'
}
function Assert-AppVisible([IntPtr]$Window) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if ($script:child.HasExited) { throw 'The installed app exited before showing its window.' }
        if ([AirPlayWindowFixture]::IsWindowVisible($Window)) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Manual startup/reopen left the app hidden.'
}
function Invoke-Duplicate([string[]]$AppArguments = @()) {
    $options = @{ FilePath = (Join-Path $app 'flutter_airplay.exe'); WorkingDirectory = $evidence; PassThru = $true }
    if ($AppArguments.Count) { $options.ArgumentList = $AppArguments }
    $duplicate = Start-Process @options
    if (-not $duplicate.WaitForExit(10000)) {
        Stop-Process -Id $duplicate.Id -Force
        throw 'A duplicate app launch did not exit.'
    }
    if ($duplicate.ExitCode -ne 0) { throw "Duplicate app launch failed: $($duplicate.ExitCode)" }
    if ($script:child.HasExited) { throw 'Duplicate launch stopped the original app.' }
}
$loginKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Run'
$loginRegistry = Get-Item -LiteralPath $loginKey -ErrorAction SilentlyContinue
$originalLogin = if ($loginRegistry) { $loginRegistry.GetValue('FlutterAirPlay', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
$originalLoginKind = if ($null -ne $originalLogin) { $loginRegistry.GetValueKind('FlutterAirPlay') } else { $null }
$approvalKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Explorer/StartupApproved/Run'
$approvalRegistry = Get-Item -LiteralPath $approvalKey -ErrorAction SilentlyContinue
$originalApproval = Read-RegistryValue $approvalKey
$originalApprovalKind = if ($null -ne $originalApproval) { $approvalRegistry.GetValueKind('FlutterAirPlay') } else { $null }
$legacyCommand = '"' + (Join-Path $app 'flutter_airplay.exe') + '"'
$loginCommand = $legacyCommand + ' --launch-at-login'
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
    # The temporary install owns only these two value names for this fixture.
    # Preserve both originals above and restore them even when a check fails.
    Remove-ItemProperty -LiteralPath $loginKey -Name FlutterAirPlay -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $approvalKey -Name FlutterAirPlay -ErrorAction SilentlyContinue
    Start-App
    Assert-AppVisible (Wait-AppWindow)
    if ($null -ne (Read-RegistryValue $loginKey)) { throw 'Manual startup created a missing login registration.' }
    Stop-App

    New-Item -Path $loginKey -Force | Out-Null
    New-Item -Path $approvalKey -Force | Out-Null
    [byte[]]$disabledApproval = @(3, 0, 0, 0, 11, 12, 13, 14, 15, 16, 17, 18)
    New-ItemProperty -Path $loginKey -Name FlutterAirPlay -Value $legacyCommand -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $approvalKey -Name FlutterAirPlay -Value $disabledApproval -PropertyType Binary -Force | Out-Null
    Start-App
    Assert-AppVisible (Wait-AppWindow)
    if ((Read-RegistryValue $loginKey) -cne $legacyCommand) { throw 'Startup migrated a disabled legacy registration.' }
    if ([Convert]::ToBase64String([byte[]](Read-RegistryValue $approvalKey)) -cne [Convert]::ToBase64String($disabledApproval)) {
        throw 'Startup modified the Task Manager disabled record.'
    }
    Stop-App

    Remove-ItemProperty -LiteralPath $approvalKey -Name FlutterAirPlay
    foreach ($foreignCommand in @('"C:\Other App\flutter_airplay.exe"', ($legacyCommand + ' --custom'))) {
        Set-ItemProperty -LiteralPath $loginKey -Name FlutterAirPlay -Value $foreignCommand
        Start-App
        Assert-AppVisible (Wait-AppWindow)
        if ((Read-RegistryValue $loginKey) -cne $foreignCommand) { throw 'Startup changed a foreign/custom login registration.' }
        Stop-App
    }

    Set-ItemProperty -LiteralPath $loginKey -Name FlutterAirPlay -Value $legacyCommand
    Start-App
    Assert-AppVisible (Wait-AppWindow)
    if ((Read-RegistryValue $loginKey) -cne $loginCommand) { throw 'Startup did not upgrade its enabled legacy registration.' }
    if ($null -ne (Read-RegistryValue $approvalKey)) { throw 'Legacy upgrade wrote a Windows startup approval record.' }
    Stop-App
    Write-Host 'PASS: manual cold startup and missing/disabled/foreign/legacy login registration policy'

    # A real shell/tray session is needed for the hidden-login integration case.
    # The native startup fixture separately covers unavailable-tray/timeout fallback.
    if ([AirPlayWindowFixture]::FindWindowW('Shell_TrayWnd', $null) -eq [IntPtr]::Zero) {
        Write-Host 'SKIP: hidden-login HWND checks require a Windows shell/tray session'
    } else {
        Start-App @('--launch-at-login')
        $window = Wait-AppWindow
        # Pass the 10-second accessibility fallback timer before calling it hidden.
        Start-Sleep -Seconds 12
        if ($child.HasExited -or [AirPlayWindowFixture]::IsWindowVisible($window)) {
            throw 'Login startup did not remain hidden with a usable tray.'
        }
        Invoke-Duplicate @('--launch-at-login')
        Start-Sleep -Milliseconds 500
        if ([AirPlayWindowFixture]::IsWindowVisible($window)) { throw 'Duplicate login launch exposed the existing window.' }
        Invoke-Duplicate
        Assert-AppVisible $window
        Stop-App

        # Issue a manual reopen as soon as the login process has an HWND, then
        # ensure completing startup cannot hide it again. Pending intent itself
        # is deterministic in the native fixture; process timing varies here.
        Start-App @('--launch-at-login')
        $window = Wait-AppWindow
        Invoke-Duplicate
        Assert-AppVisible $window
        Start-Sleep -Seconds 12
        if ($child.HasExited -or -not [AirPlayWindowFixture]::IsWindowVisible($window)) {
            throw 'Finishing login startup lost a manual reopen.'
        }
        Stop-App
        Write-Host 'PASS: login cold startup, silent login duplicate and visible manual reopen'
    }
    Write-Host 'PASS: English install, Chinese upgrade, payload and Release startup'

} finally {
    try {
        Stop-App
        $uninstaller = Join-Path $app 'unins000.exe'
        if (Test-Path -LiteralPath $uninstaller) {
            # Exercise new-command cleanup even if an earlier assertion failed.
            New-Item -Path $loginKey -Force | Out-Null
            New-ItemProperty -Path $loginKey -Name FlutterAirPlay -Value $loginCommand -PropertyType String -Force | Out-Null
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
        # Restore the original registration and approval exactly, including a
        # Task Manager disable, even when launch or uninstall fails.
        if ($null -ne $originalLogin) {
            New-ItemProperty -Path $loginKey -Name FlutterAirPlay -Value $originalLogin -PropertyType $originalLoginKind -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $loginKey -Name FlutterAirPlay -ErrorAction SilentlyContinue
        }
        if ($null -ne $originalApproval) {
            New-ItemProperty -Path $approvalKey -Name FlutterAirPlay -Value $originalApproval -PropertyType $originalApprovalKind -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $approvalKey -Name FlutterAirPlay -ErrorAction SilentlyContinue
        }
    }
}
