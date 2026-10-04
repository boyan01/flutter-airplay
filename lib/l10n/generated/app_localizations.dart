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
  /// **'Discoverable · Waiting for iPhone'**
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
  /// **'Receiver off · Not discoverable'**
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
  /// **'Connected. Waiting for the first frame.'**
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

  /// No description provided for @foregroundHelp.
  ///
  /// In en, this message translates to:
  /// **'Keep this app in the foreground · DRM content is not supported'**
  String get foregroundHelp;

  /// No description provided for @receive.
  ///
  /// In en, this message translates to:
  /// **'Receive AirPlay'**
  String get receive;

  /// No description provided for @deviceAudioHelp.
  ///
  /// In en, this message translates to:
  /// **'Audio plays on this device · DRM content is not supported'**
  String get deviceAudioHelp;

  /// No description provided for @noLogs.
  ///
  /// In en, this message translates to:
  /// **'No logs yet. Receiver activity will appear here.'**
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
  /// **'Generate a random name'**
  String get randomName;

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

  /// No description provided for @restartHelp.
  ///
  /// In en, this message translates to:
  /// **'Changing the name restarts the receiver and ends the current session.'**
  String get restartHelp;

  /// No description provided for @advanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get advanced;

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
  /// **'Native receiver operation failed'**
  String get nativeError;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Settings saved'**
  String get saved;

  /// No description provided for @checkPassed.
  ///
  /// In en, this message translates to:
  /// **'Environment check passed. The receiver is ready to start.'**
  String get checkPassed;

  /// No description provided for @selectReceiver.
  ///
  /// In en, this message translates to:
  /// **'Select “{name}”'**
  String selectReceiver(String name);

  /// No description provided for @discoverable.
  ///
  /// In en, this message translates to:
  /// **'Discoverable'**
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

  /// No description provided for @drmNotice.
  ///
  /// In en, this message translates to:
  /// **'DRM content is not supported'**
  String get drmNotice;

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
  /// **'Opening at login requires macOS 13 or later'**
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
  /// **'Only audio is available. Video will appear automatically when it arrives.'**
  String get audioOnlyHelp;

  /// No description provided for @clientConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected · {name}'**
  String clientConnected(String name);

  /// No description provided for @foregroundReceive.
  ///
  /// In en, this message translates to:
  /// **'Keep this app in the foreground to receive mirroring on iPad.'**
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

  /// No description provided for @qualityHelp.
  ///
  /// In en, this message translates to:
  /// **'Fit this device uses screen pixels and decoder capabilities, requesting up to 1440p. The sender decides the actual size. Reconnect Screen Mirroring after saving.'**
  String get qualityHelp;

  /// No description provided for @qualityUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This decoder does not support this quality'**
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

  /// No description provided for @qualityRestartHelp.
  ///
  /// In en, this message translates to:
  /// **'Changing the name or quality restarts the receiver and ends the current session.'**
  String get qualityRestartHelp;
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
