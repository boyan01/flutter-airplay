// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get settings => '设置';

  @override
  String get logs => '接收日志';

  @override
  String get sessionEnded => '投屏已结束';

  @override
  String get fullscreenFailed => '无法切换全屏';

  @override
  String get unavailable => '无法接收投屏';

  @override
  String get ready => '可被发现 · 等待 iPhone';

  @override
  String get connecting => 'iPhone 正在连接…';

  @override
  String get starting => '正在启动…';

  @override
  String get stopping => '正在停止…';

  @override
  String get off => '接收已关闭 · 不会被发现';

  @override
  String get loading => '正在读取状态…';

  @override
  String get retry => '重试';

  @override
  String get start => '打开接收';

  @override
  String get awaitingFrame => '已建立连接，等待第一帧画面';

  @override
  String get reconnectHelp => '如果长时间无画面，请在 iPhone 上重新选择。';

  @override
  String get sameWifiTv => 'iPhone 与电视连接同一 Wi-Fi';

  @override
  String get sameWifi => 'iPhone 与本机连接同一 Wi-Fi';

  @override
  String get controlCenter => '打开控制中心，点按「屏幕镜像」';

  @override
  String get check => '检查环境';

  @override
  String get viewLogs => '查看日志';

  @override
  String get rename => '修改设备名';

  @override
  String get tvHeading => '用 iPhone 投屏到这台电视';

  @override
  String get logsShort => '日志';

  @override
  String get foregroundHelp => '请保持本应用在前台 · 不支持 DRM 内容';

  @override
  String get receive => '接收投屏';

  @override
  String get deviceAudioHelp => '声音由本设备播放 · 不支持 DRM 内容';

  @override
  String get noLogs => '暂无日志。启动接收后可在这里查看运行情况。';

  @override
  String get logsCopied => '日志已复制';

  @override
  String get copyLogs => '复制日志';

  @override
  String get clear => '清空';

  @override
  String get back => '返回';

  @override
  String get confirmBack => '再次返回将断开投屏';

  @override
  String get playing => 'iPhone · 投屏中';

  @override
  String get disconnect => '断开投屏';

  @override
  String get continueWatching => '继续观看';

  @override
  String get fullscreen => '切换全屏（⌃⌘F）';

  @override
  String get videoLabel => 'iPhone 投屏画面';

  @override
  String get name => '设备名';

  @override
  String get randomName => '生成随机名称';

  @override
  String get nameHelp => '显示在 iPhone「屏幕镜像」列表中';

  @override
  String get confirm => '确认';

  @override
  String get autoStart => '打开应用时自动接收';

  @override
  String get restartHelp => '修改设备名后会重新启动接收，当前投屏将结束。';

  @override
  String get advanced => '高级';

  @override
  String get path => 'UxPlay 路径';

  @override
  String get pathHelp => '留空使用应用内置接收器';

  @override
  String get licenses => '开源许可';

  @override
  String get cancel => '取消';

  @override
  String get saving => '保存中…';

  @override
  String get done => '完成';

  @override
  String get nameRequired => '请输入设备名';

  @override
  String get nameInvalid => '设备名最多 50 个 UTF-8 字节，不能含换行';

  @override
  String get nativeError => '原生接收器操作失败';

  @override
  String get saved => '设置已保存';

  @override
  String get checkPassed => '依赖检查通过，可以启动接收器';

  @override
  String selectReceiver(String name) {
    return '选择「$name」';
  }

  @override
  String get discoverable => '可被发现';

  @override
  String get openControlCenter => '打开 iPhone 控制中心';

  @override
  String get tapMirroring => '点按「屏幕镜像」';

  @override
  String get foregroundOnly => '请保持本应用在前台';

  @override
  String get backgroundReceive => '退到后台后仍可接收投屏';

  @override
  String get backgroundLaunch => '收到投屏时自动打开应用';

  @override
  String get backgroundLaunchHelp =>
      'Android 10 及以上需在系统设置中选择 Flutter AirPlay，允许显示在其他应用上层。未授权时，可点击连接通知打开。';

  @override
  String get appPermissions => '应用权限与通知';

  @override
  String get appPermissionsHelp => '部分设备还需允许后台弹出界面。请允许通知，以便通过连接提醒打开应用。';

  @override
  String get drmNotice => '不支持 DRM 内容';

  @override
  String clientConnecting(String name) {
    return '$name 正在连接…';
  }

  @override
  String clientPlaying(String name) {
    return '$name · 投屏中';
  }

  @override
  String get general => '通用';

  @override
  String get playback => '播放';

  @override
  String get launchAtLogin => '登录时打开';

  @override
  String get keepInMenuBar => '关闭窗口后保留在菜单栏';

  @override
  String get showOnConnect => '收到投屏时显示窗口';

  @override
  String get fullscreenOnConnect => '投屏时自动全屏';

  @override
  String get alwaysOnTop => '播放窗口置顶';

  @override
  String get openApp => '打开 Flutter AirPlay';

  @override
  String get showPlayer => '显示播放窗口';

  @override
  String get quitApp => '退出 Flutter AirPlay';

  @override
  String get about => '关于 Flutter AirPlay';

  @override
  String get receiverMenu => '接收';

  @override
  String get viewMenu => '显示';

  @override
  String get windowMenu => '窗口';

  @override
  String get helpMenu => '帮助';

  @override
  String get editMenu => '编辑';

  @override
  String get hideApp => '隐藏 Flutter AirPlay';

  @override
  String get hideOthers => '隐藏其他';

  @override
  String get showAll => '显示全部';

  @override
  String get actualSize => '实际大小';

  @override
  String get fitScreen => '适合屏幕';

  @override
  String get minimize => '最小化';

  @override
  String get zoom => '缩放';

  @override
  String get close => '关闭';

  @override
  String get bringAll => '前置全部';

  @override
  String get instructions => '使用说明';

  @override
  String get undo => '撤销';

  @override
  String get redo => '重做';

  @override
  String get cut => '剪切';

  @override
  String get copy => '复制';

  @override
  String get paste => '粘贴';

  @override
  String get selectAll => '全选';

  @override
  String get enterFullscreen => '进入全屏';

  @override
  String get exitFullscreen => '退出全屏';

  @override
  String get loginUnavailable => '登录启动需要 macOS 13 或更新版本';

  @override
  String get audioPlaying => '音频播放中';

  @override
  String get videoPaused => '画面已暂停';

  @override
  String get audioContinues => '音频仍在播放';

  @override
  String get videoResumeHelp => '亮屏并继续屏幕镜像，画面会自动恢复。';

  @override
  String get audioOnlyHelp => '当前只有音频。收到投屏画面后，会自动切回视频。';

  @override
  String clientConnected(String name) {
    return '已连接 · $name';
  }

  @override
  String get foregroundReceive => '在 iPad 上接收镜像时，请保持应用在前台。';

  @override
  String get maximize => '最大化';

  @override
  String get restore => '还原';

  @override
  String get keepInTray => '关闭窗口后保留在托盘';

  @override
  String get fullscreenWindows => '切换全屏（F11）';

  @override
  String get videoQuality => '投屏清晰度';

  @override
  String get qualityAuto => '适配本机';

  @override
  String get quality720 => '流畅 · 720p';

  @override
  String get quality1080 => '标准 · 1080p';

  @override
  String get quality1440 => '高清 · 1440p';

  @override
  String get quality2160 => '超高清 · 4K';

  @override
  String get qualityHelp =>
      '适配本机最高请求 4K（3840 × 2160）。macOS 参考屏幕像素，Android 还会检查解码能力。实际尺寸由发送端决定。保存后需重新连接屏幕镜像。';

  @override
  String get qualityUnsupported => '此设备的解码器不支持此档位';

  @override
  String get screenSize => '当前屏幕';

  @override
  String get receivedSize => '实际接收';

  @override
  String get noReceivedVideo => '等待画面';

  @override
  String get saveRestart => '保存并重启';

  @override
  String get qualityRestartHelp => '修改设备名或清晰度后会重新启动接收，当前投屏将结束。';

  @override
  String get shareLogs => '分享日志文件';

  @override
  String get exportingLogs => '正在打包日志…';

  @override
  String get shareLogsFailed => '日志导出或分享失败，请重试。';

  @override
  String get shareLogsUnavailable => '此设备没有可用的文件分享应用。';

  @override
  String get clearLogView => '清空当前列表';

  @override
  String get shareLogsHelp =>
      '将历史日志、应用版本和播放信息打包为 ZIP 文件分享。清空列表会保留日志文件。日志可能包含设备和网络信息。';

  @override
  String get audioOutput => '音频输出';

  @override
  String get audioOutputAuto => '自动（推荐）';

  @override
  String get audioOutputAutoHelp => '优先低延迟，失败时切换兼容输出';

  @override
  String get audioOutputAAudio => '低延迟（AAudio）';

  @override
  String get audioOutputTrack => '兼容（AudioTrack）';

  @override
  String get audioOutputRestartHelp => '更改将在接收器下次启动时生效。请停止并启动接收器以应用新选择。';

  @override
  String get buildVersion => '版本';

  @override
  String get buildTime => '构建时间（UTC）';
}
