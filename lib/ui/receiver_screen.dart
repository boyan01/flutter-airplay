// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../receiver/receiver_model.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({
    super.key,
    required this.model,
    this.themeMode = ThemeMode.system,
    this.onThemeChanged,
  });
  final ReceiverModel model;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  static const _window = MethodChannel('org.flutterairplay/window');
  final _primaryFocus = FocusNode(debugLabel: '接收操作');
  final _fullscreenFocus = FocusNode(debugLabel: '全屏操作');
  bool _previewExpanded = false;
  bool _dialogOpen = false;
  bool _initialFocusSet = false;
  ReceiverModel get model => widget.model;
  bool get _android => model.platform == 'android';
  bool get _television => model.isTelevision;
  String get _playbackDevice => _android ? (_television ? '电视' : '本设备') : 'Mac';
  ColorScheme get colors => Theme.of(context).colorScheme;
  bool get _hasError => model.status == 'error' || model.commandError != null;
  bool get _transitioning =>
      !model.loaded ||
      model.busy ||
      {'checking', 'starting', 'stopping'}.contains(model.status);

  @override
  void initState() {
    super.initState();
    _window.setMethodCallHandler((call) async {
      if (call.method == 'fullscreenChanged' && mounted) {
        _setExpanded(call.arguments as bool);
      }
    });
    model.addListener(_initialFocus);
    model.initialize();
  }

  void _initialFocus() {
    if (!_initialFocusSet && model.loaded) {
      _initialFocusSet = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_dialogOpen && !_previewExpanded) {
          _primaryFocus.requestFocus();
        }
      });
    }
  }

  void _setExpanded(bool expanded) {
    setState(() => _previewExpanded = expanded);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_dialogOpen) {
        (expanded ? _fullscreenFocus : _primaryFocus).requestFocus();
      }
    });
  }

  Future<void> _fullscreen(bool expanded) async {
    _setExpanded(expanded);
    try {
      if (_android) {
        await SystemChrome.setEnabledSystemUIMode(
          expanded ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      } else {
        await _window.invokeMethod<void>('setFullscreen', {
          'fullscreen': expanded,
        });
      }
    } on MissingPluginException {
      // Widget tests and non-macOS hosts retain an expanded embedded preview.
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? '无法切换全屏，请使用窗口的全屏按钮')),
        );
      }
    }
  }

  @override
  void dispose() {
    _window.setMethodCallHandler(null);
    model.removeListener(_initialFocus);
    _primaryFocus.dispose();
    _fullscreenFocus.dispose();
    model.dispose();
    super.dispose();
  }

  String get _label {
    if (!model.loaded) return '准备中';
    if (_hasError) return '需要处理';
    return switch (model.status) {
      'checking' => '检查环境中',
      'starting' => '正在启动',
      'waiting' => '等待连接',
      'streaming' => '已连接',
      'stopping' => '正在停止',
      _ => '准备投屏',
    };
  }

  String get _actionLabel {
    if (!model.loaded) return '准备中…';
    if (model.status == 'stopping') return '正在停止…';
    if (_transitioning) return '请稍候…';
    if (model.active) return model.status == 'streaming' ? '停止投屏' : '停止接收';
    return _hasError ? '重新启动' : '启动接收';
  }

  void _primaryAction() {
    if (_dialogOpen) return;
    if (model.canStop) {
      model.stop();
    } else if (model.canStart) {
      model.start(model.name, model.path);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
          if (!_dialogOpen) _fullscreen(!_previewExpanded);
        },
        if (_previewExpanded)
          const SingleActivator(LogicalKeyboardKey.goBack): () {
            if (_previewExpanded && !_dialogOpen) _fullscreen(false);
          },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_previewExpanded && !_dialogOpen) _fullscreen(false);
        },
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            _primaryAction,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): _settings,
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true): _logs,
      },
      child: PopScope(
        canPop: !_previewExpanded,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _previewExpanded) _fullscreen(false);
        },
        child: FocusTraversalGroup(
          child: Scaffold(
            backgroundColor: _previewExpanded ? const Color(0xff101817) : null,
            body: SafeArea(
              child: _previewExpanded ? _expandedPreview() : _mainContent(),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _mainContent() => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 620;
      final padding = _television
          ? 32.0
          : compact
          ? 16.0
          : 24.0;
      return SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(padding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(compact),
              const SizedBox(height: 18),
              _status(compact),
              if (_hasError) ...[
                const SizedBox(height: 12),
                _errorCard(),
              ] else if (model.notice != null) ...[
                const SizedBox(height: 8),
                Semantics(liveRegion: true, child: Text(model.notice!)),
              ],
              const SizedBox(height: 18),
              SizedBox(
                height: math.max(
                  260,
                  constraints.maxHeight - (_hasError ? 360 : 276),
                ),
                child: _preview(),
              ),
              const SizedBox(height: 14),
              Text(
                '同一网络  →  iPhone 控制中心  →  屏幕镜像  →  ${model.name}',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
              ),
              const SizedBox(height: 6),
              Text(
                '声音由$_playbackDevice播放 · 不支持 DRM 内容',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: _television ? 16 : 12,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _toolbar(bool compact) => Row(
    children: [
      Icon(Icons.airplay_rounded, color: colors.primary, size: 28),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          compact ? 'AirPlay' : 'Flutter AirPlay',
          style: TextStyle(
            fontSize: _television ? 28 : 22,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      IconButton(
        key: const Key('openLogs'),
        tooltip: _android ? '接收日志' : '接收日志（⌘L）',
        onPressed: _logs,
        icon: const Icon(Icons.receipt_long_outlined),
      ),
      IconButton(
        key: const Key('openSettings'),
        tooltip: _android ? '设置' : '设置（⌘,）',
        onPressed: model.loaded ? _settings : null,
        icon: const Icon(Icons.settings_outlined),
      ),
      PopupMenuButton<ThemeMode>(
        key: const Key('appearance'),
        tooltip: '外观',
        initialValue: widget.themeMode,
        onSelected: widget.onThemeChanged,
        icon: const Icon(Icons.brightness_6_outlined),
        itemBuilder: (_) => const [
          PopupMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
          PopupMenuItem(value: ThemeMode.light, child: Text('浅色')),
          PopupMenuItem(value: ThemeMode.dark, child: Text('深色')),
        ],
      ),
    ],
  );

  Widget _status(bool compact) {
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Row(
            children: [
              Icon(
                _hasError
                    ? Icons.error_outline
                    : model.status == 'streaming'
                    ? Icons.cast_connected
                    : Icons.circle,
                size: _hasError || model.status == 'streaming' ? 20 : 10,
                color: _hasError ? colors.error : colors.primary,
              ),
              const SizedBox(width: 8),
              Text(_label, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          model.name,
          style: TextStyle(
            fontSize: _television ? 28 : 21,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          !model.loaded
              ? '正在读取接收器状态…'
              : _hasError
              ? '请按下方提示处理后重试'
              : model.status == 'stopped'
              ? '启动后，在 iPhone 的屏幕镜像列表选择此设备'
              : model.message,
          key: const Key('statusMessage'),
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      ],
    );
    final action = FilledButton.icon(
      key: Key(model.active ? 'stop' : 'start'),
      focusNode: _primaryFocus,
      autofocus: true,
      onPressed: model.canStart || model.canStop ? _primaryAction : null,
      icon: _transitioning
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(model.active ? Icons.stop_rounded : Icons.play_arrow_rounded),
      label: Text(_actionLabel),
    );
    return compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [info, const SizedBox(height: 12), action],
          )
        : Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 20),
              action,
            ],
          );
  }

  Widget _errorCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: colors.errorContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: SelectableText(
            model.commandError ?? model.message,
            style: TextStyle(color: colors.onErrorContainer),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '检查接收器环境；若连接失败，请确认 iPhone 与本设备在同一网络。',
          style: TextStyle(color: colors.onErrorContainer),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              key: const Key('check'),
              onPressed: model.editable ? () => model.check(model.path) : null,
              icon: const Icon(Icons.build_outlined),
              label: const Text('检查环境'),
            ),
            TextButton(onPressed: _settings, child: const Text('打开设置')),
            TextButton(onPressed: _logs, child: const Text('查看日志')),
          ],
        ),
      ],
    ),
  );

  Widget _preview() => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: ColoredBox(
      key: const Key('videoPreview'),
      color: const Color(0xff101817),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(padding: const EdgeInsets.all(16), child: _videoSurface()),
          Positioned(
            top: 10,
            right: 10,
            child: IconButton.filledTonal(
              key: const Key('expandPreview'),
              tooltip: _android ? '全屏观看' : '全屏观看（⌘F）',
              onPressed: () => _fullscreen(true),
              icon: const Icon(Icons.fullscreen),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _videoSurface() => model.hasVideo
      ? Center(
          child: Semantics(
            label: 'iPhone 投屏画面，${model.videoWidth} × ${model.videoHeight}',
            image: true,
            child: AspectRatio(
              aspectRatio: model.videoWidth / model.videoHeight,
              child: Texture(textureId: model.textureId),
            ),
          ),
        )
      : Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.airplay_rounded,
                  size: 48,
                  color: Color(0xff8bbab1),
                ),
                const SizedBox(height: 18),
                Text(
                  _hasError
                      ? '暂时无法接收画面'
                      : model.status == 'streaming'
                      ? '已连接，等待画面'
                      : model.active
                      ? '等待 iPhone 连接'
                      : '准备好看大屏了吗？',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: _television ? 28 : 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  model.active
                      ? '屏幕镜像 → ${model.name}'
                      : '点击“启动接收”，然后在 iPhone 上打开屏幕镜像',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color(0xffb8ccc7),
                    height: 1.5,
                    fontSize: _television ? 20 : 14,
                  ),
                ),
              ],
            ),
          ),
        );

  Widget _expandedPreview() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            IconButton(
              key: const Key('collapsePreview'),
              focusNode: _fullscreenFocus,
              autofocus: true,
              tooltip: _android ? '退出全屏（返回）' : '退出全屏（Esc）',
              color: Colors.white,
              onPressed: () => _fullscreen(false),
              icon: const Icon(Icons.fullscreen_exit),
            ),
            Expanded(
              child: Text(
                '$_label · ${model.name}',
                style: const TextStyle(color: Color(0xffb8ccc7)),
              ),
            ),
            if (model.active)
              TextButton(
                key: const Key('fullscreenStop'),
                onPressed: model.canStop ? model.stop : null,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: Text(_actionLabel),
              ),
          ],
        ),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _videoSurface(),
        ),
      ),
    ],
  );

  Future<void> _settings() async {
    if (_dialogOpen || !model.loaded) return;
    _dialogOpen = true;
    await showDialog<void>(
      context: context,
      builder: (context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.goBack): () =>
              Navigator.pop(context),
        },
        child: _SettingsDialog(model: model),
      ),
    );
    _dialogOpen = false;
    if (mounted) {
      (_previewExpanded ? _fullscreenFocus : _primaryFocus).requestFocus();
    }
  }

  Future<void> _logs() async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    await showDialog<void>(
      context: context,
      builder: (context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.goBack): () =>
              Navigator.pop(context),
        },
        child: ListenableBuilder(
          listenable: model,
          builder: (context, _) => AlertDialog(
            title: const Text('接收日志'),
            content: SizedBox(
              width: 680,
              height: math.min(360, MediaQuery.sizeOf(context).height * .45),
              child: model.logs.isEmpty
                  ? const Text('暂无日志。启动接收后可在这里查看运行情况。')
                  : ListView.builder(
                      reverse: true,
                      itemCount: model.logs.length,
                      itemBuilder: (_, index) => SelectableText(
                        model.logs[model.logs.length - 1 - index].display,
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 12,
                          height: 1.6,
                        ),
                      ),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: model.logs.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: model.logText),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('日志已复制')),
                          );
                        }
                      },
                child: const Text('复制日志'),
              ),
              TextButton(
                onPressed: model.logs.isEmpty ? null : model.clearLogs,
                child: const Text('清空'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      ),
    );
    _dialogOpen = false;
    if (mounted) {
      (_previewExpanded ? _fullscreenFocus : _primaryFocus).requestFocus();
    }
  }
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.model});
  final ReceiverModel model;
  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final _name = TextEditingController(text: widget.model.name);
  late final _path = TextEditingController(text: widget.model.path);
  String? _error;
  ReceiverModel get model => widget.model;

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final validation = model.validateName(_name.text);
    setState(() => _error = validation);
    if (validation != null || !model.editable) return;
    await model.save(_name.text, _path.text);
    if (!mounted) return;
    if (model.commandError == null) {
      Navigator.pop(context);
    } else {
      setState(() => _error = model.commandError);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => AlertDialog(
      title: const Text('接收器设置'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (model.active) ...[
                const Text('正在接收。请先停止接收，再修改设备名或路径。'),
                const SizedBox(height: 16),
              ],
              TextField(
                key: const Key('receiverName'),
                controller: _name,
                autofocus: model.editable,
                enabled: model.editable,
                decoration: InputDecoration(
                  labelText: '设备名',
                  helperText: '显示在 iPhone 的“屏幕镜像”列表中',
                  errorText: _error,
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              if (model.supportsExecutablePath)
                ExpansionTile(
                  title: const Text('高级设置'),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    TextField(
                      key: const Key('receiverPath'),
                      controller: _path,
                      enabled: model.editable,
                      decoration: const InputDecoration(
                        labelText: 'UxPlay 路径（可选）',
                        helperText: '留空使用应用自带核心',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      key: const Key('settingsCheck'),
                      onPressed: model.editable
                          ? () => model.check(_path.text)
                          : null,
                      icon: const Icon(Icons.build_outlined),
                      label: const Text('检查环境'),
                    ),
                    if (model.notice != null)
                      Semantics(liveRegion: true, child: Text(model.notice!)),
                  ],
                ),
              const SizedBox(height: 12),
              Text(
                model.platform == 'android'
                    ? 'UxPlay · GPLv3 开源'
                    : 'UxPlay + GStreamer · GPLv3 开源',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(model.active ? '返回' : '取消'),
        ),
        FilledButton(
          onPressed: model.editable ? _save : null,
          child: Text(model.busy ? '保存中…' : '保存设置'),
        ),
      ],
    ),
  );
}
