; SPDX-License-Identifier: GPL-3.0-only
; Build through windows/scripts/package_windows.ps1.
#if Ver < EncodeVer(6, 6, 0)
  #error Inno Setup 6.6 or newer is required for the adaptive wizard.
#endif
#ifndef BundleDir
  #error BundleDir must point to the staged Release application.
#endif

[Setup]
AppId={{D8393B77-9CE5-4D58-8CAC-2BD0621E7C16}
AppName=Flutter AirPlay
AppVersion={#AppVersion}
AppVerName=Flutter AirPlay {#AppVersion}
VersionInfoVersion={#FileVersion}
AppPublisher=Flutter AirPlay contributors
AppPublisherURL=https://github.com/boyan01/flutter-airplay
AppSupportURL=https://github.com/boyan01/flutter-airplay/issues
AppUpdatesURL=https://github.com/boyan01/flutter-airplay/releases
DefaultDirName={localappdata}\Programs\Flutter AirPlay
DefaultGroupName=Flutter AirPlay
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Flutter-AirPlay-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\flutter_airplay.exe
WizardStyle=modern dynamic windows11
WizardSizePercent=115
WizardImageFile={#ArtworkDir}\wizard.png
WizardSmallImageFile={#ArtworkDir}\wizard-small.png
DisableWelcomePage=no
DisableProgramGroupPage=yes
DisableDirPage=auto
UsePreviousLanguage=yes
Compression=lzma2/normal
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
AppMutex=Local\FlutterAirPlay.MainWindow
SetupMutex=Local\FlutterAirPlay.Setup
UninstallDisplayName=Flutter AirPlay
LicenseFile=..\..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"

[Messages]
english.WelcomeLabel1=Your screen, on a bigger screen.
english.WelcomeLabel2=Install Flutter AirPlay to mirror your iPhone or iPad to this PC.%n%nKeep both devices on the same network. After installation, open Screen Mirroring in Control Center and choose this receiver.%n%nWindows 10 or later (x64). Windows N needs the Media Feature Pack.
english.FinishedHeadingLabel=Ready to receive.
english.FinishedLabel=Flutter AirPlay is installed.%n%nLaunch the app, then select this PC from Screen Mirroring on your iPhone or iPad. Allow local network access if Windows asks.
chinesesimp.WelcomeLabel1=把小屏幕，搬到大屏幕。
chinesesimp.WelcomeLabel2=安装 Flutter AirPlay，将 iPhone 或 iPad 的画面投送到这台电脑。%n%n让两台设备连接同一个网络。安装后，在控制中心打开“屏幕镜像”，选择此接收器。%n%n支持 Windows 10 及以上版本（x64）。Windows N 需要 Media Feature Pack。
chinesesimp.FinishedHeadingLabel=已准备好，开始投屏。
chinesesimp.FinishedLabel=Flutter AirPlay 已安装。%n%n启动应用，然后在 iPhone 或 iPad 的“屏幕镜像”中选择这台电脑。如 Windows 提示，请允许访问本地网络。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Flutter AirPlay"; Filename: "{app}\flutter_airplay.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Flutter AirPlay"; Filename: "{app}\flutter_airplay.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\flutter_airplay.exe"; Description: "{cm:LaunchProgram,Flutter AirPlay}"; Flags: nowait postinstall skipifsilent; WorkingDir: "{app}"

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command, LegacyCommand: String;
begin
  if CurUninstallStep = usUninstall then begin
    { Remove only a login entry pointing to this installation. Keep user settings
      and pairing data, and never remove another checkout's startup entry. }
    if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
      'FlutterAirPlay', Command) then begin
      LegacyCommand := '"' + ExpandConstant('{app}\flutter_airplay.exe') + '"';
      if (CompareText(Command, LegacyCommand) = 0) or
         (CompareText(Command, LegacyCommand + ' --launch-at-login') = 0) then
        RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'FlutterAirPlay');
    end;
  end;
end;
