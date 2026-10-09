import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @showWindow.
  ///
  /// In en, this message translates to:
  /// **'Show window'**
  String get showWindow;

  /// No description provided for @startReceiver.
  ///
  /// In en, this message translates to:
  /// **'Start receiving'**
  String get startReceiver;

  /// No description provided for @stopReceiver.
  ///
  /// In en, this message translates to:
  /// **'Stop receiving'**
  String get stopReceiver;

  /// No description provided for @disconnectConnection.
  ///
  /// In en, this message translates to:
  /// **'Disconnect current connection'**
  String get disconnectConnection;

  /// No description provided for @receiverFailed.
  ///
  /// In en, this message translates to:
  /// **'Receiver failed'**
  String get receiverFailed;

  /// No description provided for @waitingForConnection.
  ///
  /// In en, this message translates to:
  /// **'Waiting for connection'**
  String get waitingForConnection;

  /// No description provided for @connectionInProgress.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connectionInProgress;

  /// No description provided for @mirroring.
  ///
  /// In en, this message translates to:
  /// **'Mirroring'**
  String get mirroring;

  /// No description provided for @playbackWindow.
  ///
  /// In en, this message translates to:
  /// **'Player window'**
  String get playbackWindow;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @logs.
  ///
  /// In en, this message translates to:
  /// **'Receiver logs'**
  String get logs;

  /// No description provided for @sessionEnded.
  ///
  /// In en, this message translates to:
  /// **'Mirroring ended'**
  String get sessionEnded;

  /// No description provided for @fullscreenFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to toggle fullscreen'**
  String get fullscreenFailed;

  /// No description provided for @unavailable.
  ///
  /// In en, this message translates to:
  /// **'Unable to receive'**
  String get unavailable;

  /// No description provided for @ready.
  ///
  /// In en, this message translates to:
  /// **'Waiting for iPhone'**
  String get ready;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'iPhone is connecting…'**
  String get connecting;

  /// No description provided for @starting.
  ///
  /// In en, this message translates to:
  /// **'Starting…'**
  String get starting;

  /// No description provided for @stopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping…'**
  String get stopping;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Receiver off'**
  String get off;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading receiver status…'**
  String get loading;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @start.
  ///
  /// In en, this message translates to:
  /// **'Turn on receiver'**
  String get start;

  /// No description provided for @awaitingFrame.
  ///
  /// In en, this message translates to:
  /// **'Connected. Waiting for video.'**
  String get awaitingFrame;

  /// No description provided for @reconnectHelp.
  ///
  /// In en, this message translates to:
  /// **'If no picture appears, select this receiver again on your iPhone.'**
  String get reconnectHelp;

  /// No description provided for @sameWifiTv.
  ///
  /// In en, this message translates to:
  /// **'Connect iPhone and TV to the same Wi-Fi'**
  String get sameWifiTv;

  /// No description provided for @sameWifi.
  ///
  /// In en, this message translates to:
  /// **'Connect iPhone and this device to the same Wi-Fi'**
  String get sameWifi;

  /// No description provided for @controlCenter.
  ///
  /// In en, this message translates to:
  /// **'Open Control Center and tap Screen Mirroring'**
  String get controlCenter;

  /// No description provided for @check.
  ///
  /// In en, this message translates to:
  /// **'Check environment'**
  String get check;

  /// No description provided for @viewLogs.
  ///
  /// In en, this message translates to:
  /// **'View logs'**
  String get viewLogs;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename device'**
  String get rename;

  /// No description provided for @tvHeading.
  ///
  /// In en, this message translates to:
  /// **'Mirror your iPhone to this TV'**
  String get tvHeading;

  /// No description provided for @logsShort.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logsShort;

  /// No description provided for @receive.
  ///
  /// In en, this message translates to:
  /// **'Receive AirPlay'**
  String get receive;

  /// No description provided for @noLogs.
  ///
  /// In en, this message translates to:
  /// **'No logs yet'**
  String get noLogs;

  /// No description provided for @logsCopied.
  ///
  /// In en, this message translates to:
  /// **'Logs copied'**
  String get logsCopied;

  /// No description provided for @copyLogs.
  ///
  /// In en, this message translates to:
  /// **'Copy logs'**
  String get copyLogs;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @confirmBack.
  ///
  /// In en, this message translates to:
  /// **'Press Back again to disconnect'**
  String get confirmBack;

  /// No description provided for @playing.
  ///
  /// In en, this message translates to:
  /// **'iPhone · Mirroring'**
  String get playing;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @continueWatching.
  ///
  /// In en, this message translates to:
  /// **'Continue watching'**
  String get continueWatching;

  /// No description provided for @fullscreen.
  ///
  /// In en, this message translates to:
  /// **'Toggle fullscreen (⌃⌘F)'**
  String get fullscreen;

  /// No description provided for @videoLabel.
  ///
  /// In en, this message translates to:
  /// **'iPhone mirror display'**
  String get videoLabel;

  /// No description provided for @name.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get name;

  /// No description provided for @randomName.
  ///
  /// In en, this message translates to:
  /// **'Random name'**
  String get randomName;

  /// No description provided for @reset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reset;

  /// No description provided for @playbackBuffer.
  ///
  /// In en, this message translates to:
  /// **'Playback buffer'**
  String get playbackBuffer;

  /// No description provided for @playbackBufferDefault.
  ///
  /// In en, this message translates to:
  /// **'Default ({milliseconds} ms)'**
  String playbackBufferDefault(int milliseconds);

  /// No description provided for @playbackBufferValue.
  ///
  /// In en, this message translates to:
  /// **'{milliseconds} ms'**
  String playbackBufferValue(int milliseconds);

  /// No description provided for @playbackBufferHelp.
  ///
  /// In en, this message translates to:
  /// **'Lower values reduce delay but may cause stuttering or audio dropouts. Audio and video share this buffer. This is not the total mirroring delay.'**
  String get playbackBufferHelp;

  /// No description provided for @settingsApplyHelp.
  ///
  /// In en, this message translates to:
  /// **'Applies automatically while waiting, or after the current connection ends.'**
  String get settingsApplyHelp;

  /// No description provided for @nameHelp.
  ///
  /// In en, this message translates to:
  /// **'Shown in iPhone Screen Mirroring'**
  String get nameHelp;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @autoStart.
  ///
  /// In en, this message translates to:
  /// **'Receive automatically on launch'**
  String get autoStart;

  /// No description provided for @advanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get advanced;

  /// No description provided for @fastPairing.
  ///
  /// In en, this message translates to:
  /// **'Fast pairing'**
  String get fastPairing;

  /// No description provided for @fastPairingHelp.
  ///
  /// In en, this message translates to:
  /// **'Try to reduce connection time. Turn off if connections fail.'**
  String get fastPairingHelp;

  /// No description provided for @path.
  ///
  /// In en, this message translates to:
  /// **'UxPlay path'**
  String get path;

  /// No description provided for @pathHelp.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to use the bundled receiver'**
  String get pathHelp;

  /// No description provided for @licenses.
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get licenses;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @saving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get saving;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @nameRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a device name'**
  String get nameRequired;

  /// No description provided for @nameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Use at most 50 UTF-8 bytes, with no control characters'**
  String get nameInvalid;

  /// No description provided for @nativeError.
  ///
  /// In en, this message translates to:
  /// **'Receiver operation failed'**
  String get nativeError;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Settings saved'**
  String get saved;

  /// No description provided for @checkPassed.
  ///
  /// In en, this message translates to:
  /// **'Check passed. Ready to receive AirPlay.'**
  String get checkPassed;

  /// No description provided for @selectReceiver.
  ///
  /// In en, this message translates to:
  /// **'Select “{name}”'**
  String selectReceiver(String name);

  /// No description provided for @discoverable.
  ///
  /// In en, this message translates to:
  /// **'Waiting for iPhone'**
  String get discoverable;

  /// No description provided for @openControlCenter.
  ///
  /// In en, this message translates to:
  /// **'Open iPhone Control Center'**
  String get openControlCenter;

  /// No description provided for @tapMirroring.
  ///
  /// In en, this message translates to:
  /// **'Tap Screen Mirroring'**
  String get tapMirroring;

  /// No description provided for @foregroundOnly.
  ///
  /// In en, this message translates to:
  /// **'Keep this app in the foreground'**
  String get foregroundOnly;

  /// No description provided for @backgroundReceive.
  ///
  /// In en, this message translates to:
  /// **'AirPlay reception continues in the background'**
  String get backgroundReceive;

  /// No description provided for @backgroundLaunch.
  ///
  /// In en, this message translates to:
  /// **'Open the app when AirPlay connects'**
  String get backgroundLaunch;

  /// No description provided for @backgroundLaunchHelp.
  ///
  /// In en, this message translates to:
  /// **'On Android 10 or later, select Flutter AirPlay in system settings and allow display over other apps. Otherwise, tap the connection notification to open.'**
  String get backgroundLaunchHelp;

  /// No description provided for @appPermissions.
  ///
  /// In en, this message translates to:
  /// **'App permissions and notifications'**
  String get appPermissions;

  /// No description provided for @appPermissionsHelp.
  ///
  /// In en, this message translates to:
  /// **'Some devices also require permission to open windows from the background. Allow notifications to open the app from connection alerts.'**
  String get appPermissionsHelp;

  /// No description provided for @clientConnecting.
  ///
  /// In en, this message translates to:
  /// **'{name} is connecting…'**
  String clientConnecting(String name);

  /// No description provided for @clientPlaying.
  ///
  /// In en, this message translates to:
  /// **'{name} · Mirroring'**
  String clientPlaying(String name);

  /// No description provided for @general.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get general;

  /// No description provided for @playback.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get playback;

  /// No description provided for @launchAtLogin.
  ///
  /// In en, this message translates to:
  /// **'Open at login'**
  String get launchAtLogin;

  /// No description provided for @keepInMenuBar.
  ///
  /// In en, this message translates to:
  /// **'Keep in menu bar when the window closes'**
  String get keepInMenuBar;

  /// No description provided for @showOnConnect.
  ///
  /// In en, this message translates to:
  /// **'Show window when mirroring starts'**
  String get showOnConnect;

  /// No description provided for @fullscreenOnConnect.
  ///
  /// In en, this message translates to:
  /// **'Enter fullscreen when mirroring starts'**
  String get fullscreenOnConnect;

  /// No description provided for @alwaysOnTop.
  ///
  /// In en, this message translates to:
  /// **'Keep player on top'**
  String get alwaysOnTop;

  /// No description provided for @openApp.
  ///
  /// In en, this message translates to:
  /// **'Open Flutter AirPlay'**
  String get openApp;

  /// No description provided for @showPlayer.
  ///
  /// In en, this message translates to:
  /// **'Show player window'**
  String get showPlayer;

  /// No description provided for @quitApp.
  ///
  /// In en, this message translates to:
  /// **'Quit Flutter AirPlay'**
  String get quitApp;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About Flutter AirPlay'**
  String get about;

  /// No description provided for @receiverMenu.
  ///
  /// In en, this message translates to:
  /// **'Receiver'**
  String get receiverMenu;

  /// No description provided for @viewMenu.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get viewMenu;

  /// No description provided for @windowMenu.
  ///
  /// In en, this message translates to:
  /// **'Window'**
  String get windowMenu;

  /// No description provided for @helpMenu.
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get helpMenu;

  /// No description provided for @editMenu.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editMenu;

  /// No description provided for @hideApp.
  ///
  /// In en, this message translates to:
  /// **'Hide Flutter AirPlay'**
  String get hideApp;

  /// No description provided for @hideOthers.
  ///
  /// In en, this message translates to:
  /// **'Hide Others'**
  String get hideOthers;

  /// No description provided for @showAll.
  ///
  /// In en, this message translates to:
  /// **'Show All'**
  String get showAll;

  /// No description provided for @actualSize.
  ///
  /// In en, this message translates to:
  /// **'Actual Size'**
  String get actualSize;

  /// No description provided for @fitScreen.
  ///
  /// In en, this message translates to:
  /// **'Fit to Screen'**
  String get fitScreen;

  /// No description provided for @minimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize'**
  String get minimize;

  /// No description provided for @zoom.
  ///
  /// In en, this message translates to:
  /// **'Zoom'**
  String get zoom;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @bringAll.
  ///
  /// In en, this message translates to:
  /// **'Bring All to Front'**
  String get bringAll;

  /// No description provided for @instructions.
  ///
  /// In en, this message translates to:
  /// **'Instructions'**
  String get instructions;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// No description provided for @redo.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get redo;

  /// No description provided for @cut.
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get cut;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @paste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get paste;

  /// No description provided for @selectAll.
  ///
  /// In en, this message translates to:
  /// **'Select All'**
  String get selectAll;

  /// No description provided for @enterFullscreen.
  ///
  /// In en, this message translates to:
  /// **'Enter Full Screen'**
  String get enterFullscreen;

  /// No description provided for @exitFullscreen.
  ///
  /// In en, this message translates to:
  /// **'Exit Full Screen'**
  String get exitFullscreen;

  /// No description provided for @loginUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Login startup is unavailable on this system (macOS requires 13 or later).'**
  String get loginUnavailable;

  /// No description provided for @audioPlaying.
  ///
  /// In en, this message translates to:
  /// **'Audio playing'**
  String get audioPlaying;

  /// No description provided for @videoPaused.
  ///
  /// In en, this message translates to:
  /// **'Video paused'**
  String get videoPaused;

  /// No description provided for @audioContinues.
  ///
  /// In en, this message translates to:
  /// **'Audio is still playing'**
  String get audioContinues;

  /// No description provided for @videoResumeHelp.
  ///
  /// In en, this message translates to:
  /// **'Wake your iPhone and continue Screen Mirroring. Video will resume automatically.'**
  String get videoResumeHelp;

  /// No description provided for @audioOnlyHelp.
  ///
  /// In en, this message translates to:
  /// **'Video will appear automatically when it arrives.'**
  String get audioOnlyHelp;

  /// No description provided for @clientConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected · {name}'**
  String clientConnected(String name);

  /// No description provided for @foregroundReceive.
  ///
  /// In en, this message translates to:
  /// **'Keep this app in the foreground'**
  String get foregroundReceive;

  /// No description provided for @maximize.
  ///
  /// In en, this message translates to:
  /// **'Maximize'**
  String get maximize;

  /// No description provided for @restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// No description provided for @keepInTray.
  ///
  /// In en, this message translates to:
  /// **'Keep in system tray when the window closes'**
  String get keepInTray;

  /// No description provided for @fullscreenWindows.
  ///
  /// In en, this message translates to:
  /// **'Toggle fullscreen (F11)'**
  String get fullscreenWindows;

  /// No description provided for @videoQuality.
  ///
  /// In en, this message translates to:
  /// **'Mirroring quality'**
  String get videoQuality;

  /// No description provided for @qualityAuto.
  ///
  /// In en, this message translates to:
  /// **'Fit this device'**
  String get qualityAuto;

  /// No description provided for @quality720.
  ///
  /// In en, this message translates to:
  /// **'Smooth · 720p'**
  String get quality720;

  /// No description provided for @quality1080.
  ///
  /// In en, this message translates to:
  /// **'Standard · 1080p'**
  String get quality1080;

  /// No description provided for @quality1440.
  ///
  /// In en, this message translates to:
  /// **'High · 1440p'**
  String get quality1440;

  /// No description provided for @quality2160.
  ///
  /// In en, this message translates to:
  /// **'Ultra HD · 4K'**
  String get quality2160;

  /// No description provided for @qualityHelp.
  ///
  /// In en, this message translates to:
  /// **'Automatically fits your device, up to 4K. The actual video size depends on your iPhone.'**
  String get qualityHelp;

  /// No description provided for @qualityUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This quality is unavailable on this device'**
  String get qualityUnsupported;

  /// No description provided for @screenSize.
  ///
  /// In en, this message translates to:
  /// **'Current screen'**
  String get screenSize;

  /// No description provided for @receivedSize.
  ///
  /// In en, this message translates to:
  /// **'Received video'**
  String get receivedSize;

  /// No description provided for @noReceivedVideo.
  ///
  /// In en, this message translates to:
  /// **'Waiting for video'**
  String get noReceivedVideo;

  /// No description provided for @saveRestart.
  ///
  /// In en, this message translates to:
  /// **'Save and restart'**
  String get saveRestart;

  /// No description provided for @shareLogs.
  ///
  /// In en, this message translates to:
  /// **'Share log file'**
  String get shareLogs;

  /// No description provided for @exportingLogs.
  ///
  /// In en, this message translates to:
  /// **'Preparing logs…'**
  String get exportingLogs;

  /// No description provided for @shareLogsFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not export or share logs. Please try again.'**
  String get shareLogsFailed;

  /// No description provided for @shareLogsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No file sharing app is available on this device.'**
  String get shareLogsUnavailable;

  /// No description provided for @clearLogView.
  ///
  /// In en, this message translates to:
  /// **'Clear current list'**
  String get clearLogView;

  /// No description provided for @shareLogsHelp.
  ///
  /// In en, this message translates to:
  /// **'Shares saved logs, app version and playback information as a ZIP file. Clearing this list keeps saved logs. Logs may contain device and network information.'**
  String get shareLogsHelp;

  /// No description provided for @audioOutput.
  ///
  /// In en, this message translates to:
  /// **'Audio output'**
  String get audioOutput;

  /// No description provided for @audioOutputAuto.
  ///
  /// In en, this message translates to:
  /// **'Automatic (recommended)'**
  String get audioOutputAuto;

  /// No description provided for @audioOutputAutoHelp.
  ///
  /// In en, this message translates to:
  /// **'Prefer low latency; switch to compatible output on failure'**
  String get audioOutputAutoHelp;

  /// No description provided for @audioOutputAAudio.
  ///
  /// In en, this message translates to:
  /// **'Low latency'**
  String get audioOutputAAudio;

  /// No description provided for @audioOutputTrack.
  ///
  /// In en, this message translates to:
  /// **'Compatible'**
  String get audioOutputTrack;

  /// No description provided for @buildVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get buildVersion;

  /// No description provided for @buildTime.
  ///
  /// In en, this message translates to:
  /// **'Built at'**
  String get buildTime;

  /// No description provided for @showPlaybackStats.
  ///
  /// In en, this message translates to:
  /// **'Playback statistics overlay'**
  String get showPlaybackStats;

  /// No description provided for @showPlaybackStatsHelp.
  ///
  /// In en, this message translates to:
  /// **'Show codec, submission frame rate and scheduler drops while mirroring.'**
  String get showPlaybackStatsHelp;

  /// No description provided for @playbackStatsWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for playback statistics…'**
  String get playbackStatsWaiting;

  /// No description provided for @playbackStatsFps.
  ///
  /// In en, this message translates to:
  /// **'Submission FPS'**
  String get playbackStatsFps;

  /// No description provided for @playbackStatsDropped.
  ///
  /// In en, this message translates to:
  /// **'Scheduler drops'**
  String get playbackStatsDropped;

  /// No description provided for @playbackStatsSubmitted.
  ///
  /// In en, this message translates to:
  /// **'Submitted frames'**
  String get playbackStatsSubmitted;

  /// No description provided for @playbackStatsPending.
  ///
  /// In en, this message translates to:
  /// **'Pending frames'**
  String get playbackStatsPending;

  /// No description provided for @playbackStatsQueued.
  ///
  /// In en, this message translates to:
  /// **'Input queue'**
  String get playbackStatsQueued;

  /// No description provided for @playbackStatsHelp.
  ///
  /// In en, this message translates to:
  /// **'Submissions are not measured screen presentations. Drops exclude network loss.'**
  String get playbackStatsHelp;

  /// No description provided for @launchAtLoginHelp.
  ///
  /// In en, this message translates to:
  /// **'Open this app after you sign in to your desktop. Keep the app in a permanent installation location. Receiving automatically is a separate option.'**
  String get launchAtLoginHelp;

  /// No description provided for @loginError.
  ///
  /// In en, this message translates to:
  /// **'Unable to read or change startup registration. Check system permissions and the installation location, then refresh.'**
  String get loginError;

  /// No description provided for @loginNotApplied.
  ///
  /// In en, this message translates to:
  /// **'The system has not applied this change. Check Login Items or Startup Apps for approval, then refresh.'**
  String get loginNotApplied;

  /// No description provided for @refreshLogin.
  ///
  /// In en, this message translates to:
  /// **'Refresh startup status'**
  String get refreshLogin;

  /// No description provided for @cancelLoginRequest.
  ///
  /// In en, this message translates to:
  /// **'Cancel startup request'**
  String get cancelLoginRequest;

  /// No description provided for @appUpdates.
  ///
  /// In en, this message translates to:
  /// **'App updates'**
  String get appUpdates;

  /// No description provided for @automaticallyCheckForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Automatically check for updates'**
  String get automaticallyCheckForUpdates;

  /// No description provided for @automaticallyCheckForUpdatesHelp.
  ///
  /// In en, this message translates to:
  /// **'Check periodically. You choose when to install.'**
  String get automaticallyCheckForUpdatesHelp;

  /// No description provided for @checkForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkForUpdates;

  /// No description provided for @checkingForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get checkingForUpdates;

  /// No description provided for @viewUpdate.
  ///
  /// In en, this message translates to:
  /// **'View update'**
  String get viewUpdate;

  /// No description provided for @downloadUpdate.
  ///
  /// In en, this message translates to:
  /// **'Download update'**
  String get downloadUpdate;

  /// No description provided for @preparingUpdate.
  ///
  /// In en, this message translates to:
  /// **'Preparing update…'**
  String get preparingUpdate;

  /// No description provided for @installingUpdate.
  ///
  /// In en, this message translates to:
  /// **'Installing update…'**
  String get installingUpdate;

  /// No description provided for @updateRestartHelp.
  ///
  /// In en, this message translates to:
  /// **'Flutter AirPlay will restart to finish installing the update.'**
  String get updateRestartHelp;

  /// No description provided for @updateBackgroundDownload.
  ///
  /// In en, this message translates to:
  /// **'You can close this window. The download will continue in the background.'**
  String get updateBackgroundDownload;

  /// No description provided for @updateLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updateLater;

  /// No description provided for @cancelUpdateDownload.
  ///
  /// In en, this message translates to:
  /// **'Cancel download'**
  String get cancelUpdateDownload;

  /// No description provided for @updateCurrentVersion.
  ///
  /// In en, this message translates to:
  /// **'Current version {version}'**
  String updateCurrentVersion(String version);

  /// No description provided for @updateReleaseNotes.
  ///
  /// In en, this message translates to:
  /// **'What’s new'**
  String get updateReleaseNotes;

  /// No description provided for @updateFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to complete the update'**
  String get updateFailed;

  /// No description provided for @updateToVersion.
  ///
  /// In en, this message translates to:
  /// **'Update to {version}…'**
  String updateToVersion(String version);

  /// No description provided for @viewUpdateProgress.
  ///
  /// In en, this message translates to:
  /// **'View download progress'**
  String get viewUpdateProgress;

  /// No description provided for @installAndRestart.
  ///
  /// In en, this message translates to:
  /// **'Install and restart'**
  String get installAndRestart;

  /// No description provided for @updateInterruptTitle.
  ///
  /// In en, this message translates to:
  /// **'Install update'**
  String get updateInterruptTitle;

  /// No description provided for @updateInterruptMessage.
  ///
  /// In en, this message translates to:
  /// **'Installing this update will interrupt the current AirPlay connection and restart Flutter AirPlay.'**
  String get updateInterruptMessage;

  /// No description provided for @updateInstallAndDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect and Install'**
  String get updateInstallAndDisconnect;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading update…'**
  String get updateDownloading;

  /// No description provided for @updateDownloadingProgress.
  ///
  /// In en, this message translates to:
  /// **'Downloading update… {percent}%'**
  String updateDownloadingProgress(int percent);

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is available'**
  String updateAvailable(String version);

  /// No description provided for @updateAvailableUnknownVersion.
  ///
  /// In en, this message translates to:
  /// **'An update is available'**
  String get updateAvailableUnknownVersion;

  /// No description provided for @updateReady.
  ///
  /// In en, this message translates to:
  /// **'Update ready to install'**
  String get updateReady;

  /// No description provided for @updatesUpToDate.
  ///
  /// In en, this message translates to:
  /// **'No new version available'**
  String get updatesUpToDate;

  /// No description provided for @updatesNotChecked.
  ///
  /// In en, this message translates to:
  /// **'Updates have not been checked yet'**
  String get updatesNotChecked;

  /// No description provided for @updateCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to check for updates'**
  String get updateCheckFailed;

  /// No description provided for @retryUpdateCheck.
  ///
  /// In en, this message translates to:
  /// **'Retry update check'**
  String get retryUpdateCheck;

  /// No description provided for @updatesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'App updates are unavailable. Check the update configuration.'**
  String get updatesUnavailable;

  /// No description provided for @updatesInitializing.
  ///
  /// In en, this message translates to:
  /// **'Loading update settings…'**
  String get updatesInitializing;

  /// No description provided for @updateLastChecked.
  ///
  /// In en, this message translates to:
  /// **'Last checked: {time}'**
  String updateLastChecked(String time);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
