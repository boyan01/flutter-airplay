// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settings => 'Settings';

  @override
  String get logs => 'Receiver logs';

  @override
  String get sessionEnded => 'Mirroring ended';

  @override
  String get fullscreenFailed => 'Unable to toggle fullscreen';

  @override
  String get unavailable => 'Unable to receive';

  @override
  String get ready => 'Waiting for iPhone';

  @override
  String get connecting => 'iPhone is connecting…';

  @override
  String get starting => 'Starting…';

  @override
  String get stopping => 'Stopping…';

  @override
  String get off => 'Receiver off';

  @override
  String get loading => 'Loading receiver status…';

  @override
  String get retry => 'Retry';

  @override
  String get start => 'Turn on receiver';

  @override
  String get awaitingFrame => 'Connected. Waiting for video.';

  @override
  String get reconnectHelp =>
      'If no picture appears, select this receiver again on your iPhone.';

  @override
  String get sameWifiTv => 'Connect iPhone and TV to the same Wi-Fi';

  @override
  String get sameWifi => 'Connect iPhone and this device to the same Wi-Fi';

  @override
  String get controlCenter => 'Open Control Center and tap Screen Mirroring';

  @override
  String get check => 'Check environment';

  @override
  String get viewLogs => 'View logs';

  @override
  String get rename => 'Rename device';

  @override
  String get tvHeading => 'Mirror your iPhone to this TV';

  @override
  String get logsShort => 'Logs';

  @override
  String get receive => 'Receive AirPlay';

  @override
  String get noLogs => 'No logs yet';

  @override
  String get logsCopied => 'Logs copied';

  @override
  String get copyLogs => 'Copy logs';

  @override
  String get clear => 'Clear';

  @override
  String get back => 'Back';

  @override
  String get confirmBack => 'Press Back again to disconnect';

  @override
  String get playing => 'iPhone · Mirroring';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get continueWatching => 'Continue watching';

  @override
  String get fullscreen => 'Toggle fullscreen (⌃⌘F)';

  @override
  String get videoLabel => 'iPhone mirror display';

  @override
  String get name => 'Device name';

  @override
  String get randomName => 'Random name';

  @override
  String get reset => 'Reset';

  @override
  String get settingsApplyHelp =>
      'Applies automatically while waiting, or after the current connection ends.';

  @override
  String get nameHelp => 'Shown in iPhone Screen Mirroring';

  @override
  String get confirm => 'Confirm';

  @override
  String get autoStart => 'Receive automatically on launch';

  @override
  String get advanced => 'Advanced';

  @override
  String get fastPairing => 'Fast pairing';

  @override
  String get fastPairingHelp =>
      'Try to reduce connection time. Turn off if connections fail.';

  @override
  String get path => 'UxPlay path';

  @override
  String get pathHelp => 'Leave empty to use the bundled receiver';

  @override
  String get licenses => 'Open-source licenses';

  @override
  String get cancel => 'Cancel';

  @override
  String get saving => 'Saving…';

  @override
  String get done => 'Done';

  @override
  String get nameRequired => 'Enter a device name';

  @override
  String get nameInvalid =>
      'Use at most 50 UTF-8 bytes, with no control characters';

  @override
  String get nativeError => 'Receiver operation failed';

  @override
  String get saved => 'Settings saved';

  @override
  String get checkPassed => 'Check passed. Ready to receive AirPlay.';

  @override
  String selectReceiver(String name) {
    return 'Select “$name”';
  }

  @override
  String get discoverable => 'Waiting for iPhone';

  @override
  String get openControlCenter => 'Open iPhone Control Center';

  @override
  String get tapMirroring => 'Tap Screen Mirroring';

  @override
  String get foregroundOnly => 'Keep this app in the foreground';

  @override
  String get backgroundReceive =>
      'AirPlay reception continues in the background';

  @override
  String get backgroundLaunch => 'Open the app when AirPlay connects';

  @override
  String get backgroundLaunchHelp =>
      'On Android 10 or later, select Flutter AirPlay in system settings and allow display over other apps. Otherwise, tap the connection notification to open.';

  @override
  String get appPermissions => 'App permissions and notifications';

  @override
  String get appPermissionsHelp =>
      'Some devices also require permission to open windows from the background. Allow notifications to open the app from connection alerts.';

  @override
  String clientConnecting(String name) {
    return '$name is connecting…';
  }

  @override
  String clientPlaying(String name) {
    return '$name · Mirroring';
  }

  @override
  String get general => 'General';

  @override
  String get playback => 'Playback';

  @override
  String get launchAtLogin => 'Open at login';

  @override
  String get keepInMenuBar => 'Keep in menu bar when the window closes';

  @override
  String get showOnConnect => 'Show window when mirroring starts';

  @override
  String get fullscreenOnConnect => 'Enter fullscreen when mirroring starts';

  @override
  String get alwaysOnTop => 'Keep player on top';

  @override
  String get openApp => 'Open Flutter AirPlay';

  @override
  String get showPlayer => 'Show player window';

  @override
  String get quitApp => 'Quit Flutter AirPlay';

  @override
  String get about => 'About Flutter AirPlay';

  @override
  String get receiverMenu => 'Receiver';

  @override
  String get viewMenu => 'View';

  @override
  String get windowMenu => 'Window';

  @override
  String get helpMenu => 'Help';

  @override
  String get editMenu => 'Edit';

  @override
  String get hideApp => 'Hide Flutter AirPlay';

  @override
  String get hideOthers => 'Hide Others';

  @override
  String get showAll => 'Show All';

  @override
  String get actualSize => 'Actual Size';

  @override
  String get fitScreen => 'Fit to Screen';

  @override
  String get minimize => 'Minimize';

  @override
  String get zoom => 'Zoom';

  @override
  String get close => 'Close';

  @override
  String get bringAll => 'Bring All to Front';

  @override
  String get instructions => 'Instructions';

  @override
  String get undo => 'Undo';

  @override
  String get redo => 'Redo';

  @override
  String get cut => 'Cut';

  @override
  String get copy => 'Copy';

  @override
  String get paste => 'Paste';

  @override
  String get selectAll => 'Select All';

  @override
  String get enterFullscreen => 'Enter Full Screen';

  @override
  String get exitFullscreen => 'Exit Full Screen';

  @override
  String get loginUnavailable => 'Opening at login requires macOS 13 or later';

  @override
  String get audioPlaying => 'Audio playing';

  @override
  String get videoPaused => 'Video paused';

  @override
  String get audioContinues => 'Audio is still playing';

  @override
  String get videoResumeHelp =>
      'Wake your iPhone and continue Screen Mirroring. Video will resume automatically.';

  @override
  String get audioOnlyHelp =>
      'Video will appear automatically when it arrives.';

  @override
  String clientConnected(String name) {
    return 'Connected · $name';
  }

  @override
  String get foregroundReceive => 'Keep this app in the foreground';

  @override
  String get maximize => 'Maximize';

  @override
  String get restore => 'Restore';

  @override
  String get keepInTray => 'Keep in system tray when the window closes';

  @override
  String get fullscreenWindows => 'Toggle fullscreen (F11)';

  @override
  String get videoQuality => 'Mirroring quality';

  @override
  String get qualityAuto => 'Fit this device';

  @override
  String get quality720 => 'Smooth · 720p';

  @override
  String get quality1080 => 'Standard · 1080p';

  @override
  String get quality1440 => 'High · 1440p';

  @override
  String get quality2160 => 'Ultra HD · 4K';

  @override
  String get qualityHelp =>
      'Automatically fits your device, up to 4K. The actual video size depends on your iPhone.';

  @override
  String get qualityUnsupported => 'This quality is unavailable on this device';

  @override
  String get screenSize => 'Current screen';

  @override
  String get receivedSize => 'Received video';

  @override
  String get noReceivedVideo => 'Waiting for video';

  @override
  String get saveRestart => 'Save and restart';

  @override
  String get shareLogs => 'Share log file';

  @override
  String get exportingLogs => 'Preparing logs…';

  @override
  String get shareLogsFailed =>
      'Could not export or share logs. Please try again.';

  @override
  String get shareLogsUnavailable =>
      'No file sharing app is available on this device.';

  @override
  String get clearLogView => 'Clear current list';

  @override
  String get shareLogsHelp =>
      'Shares saved logs, app version and playback information as a ZIP file. Clearing this list keeps saved logs. Logs may contain device and network information.';

  @override
  String get audioOutput => 'Audio output';

  @override
  String get audioOutputAuto => 'Automatic (recommended)';

  @override
  String get audioOutputAutoHelp =>
      'Prefer low latency; switch to compatible output on failure';

  @override
  String get audioOutputAAudio => 'Low latency';

  @override
  String get audioOutputTrack => 'Compatible';

  @override
  String get buildVersion => 'Version';

  @override
  String get buildTime => 'Built at';

  @override
  String get showPlaybackStats => 'Playback statistics overlay';

  @override
  String get showPlaybackStatsHelp =>
      'Show codec, submission frame rate and scheduler drops while mirroring.';

  @override
  String get playbackStatsWaiting => 'Waiting for playback statistics…';

  @override
  String get playbackStatsFps => 'Submission FPS';

  @override
  String get playbackStatsDropped => 'Scheduler drops';

  @override
  String get playbackStatsSubmitted => 'Submitted frames';

  @override
  String get playbackStatsPending => 'Pending frames';

  @override
  String get playbackStatsQueued => 'Input queue';

  @override
  String get playbackStatsHelp =>
      'Submissions are not measured screen presentations. Drops exclude network loss.';
}
