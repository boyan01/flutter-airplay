// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'receiver/receiver_model.dart';
import 'receiver/receiver_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ReceiverApp(model: ReceiverModel(NativeReceiverRepository())));
}

class ReceiverApp extends StatelessWidget {
  const ReceiverApp({super.key, required this.model});
  final ReceiverModel model;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flutter AirPlay',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff23786e)),
      scaffoldBackgroundColor: const Color(0xfff4f6f5),
      fontFamily: '.AppleSystemUIFont',
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xfff7f9f8),
        border: OutlineInputBorder(),
      ),
    ),
    home: ReceiverScreen(model: model),
  );
}

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key, required this.model});
  final ReceiverModel model;
  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final _name = TextEditingController();
  final _path = TextEditingController();
  bool _settingsLoaded = false;
  bool _previewExpanded = false;
  ReceiverModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    model.addListener(_syncSettings);
    model.initialize();
  }

  void _syncSettings() {
    if (model.loaded && !_settingsLoaded) {
      _name.text = model.name;
      _path.text = model.path;
      _settingsLoaded = true;
    }
  }

  @override
  void dispose() {
    model.removeListener(_syncSettings);
    model.dispose();
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  String get _label => switch (model.status) {
    'checking' => '检查依赖',
    'starting' => '启动中',
    'waiting' => '等待连接',
    'streaming' => '正在接收',
    'stopping' => '停止中',
    'error' => '需要处理',
    _ => '已停止',
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => _previewExpanded
        ? _expandedPreview()
        : Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(30, 24, 30, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xffe0eee9),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.airplay_rounded,
                            color: Color(0xff23786e),
                            size: 30,
                          ),
                        ),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Flutter AirPlay',
                                style: TextStyle(
                                  fontSize: 25,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                '把 iPhone 的屏幕与声音带到 Mac',
                                style: TextStyle(color: Color(0xff5b6964)),
                              ),
                            ],
                          ),
                        ),
                        const Chip(label: Text('Flutter 内嵌画面')),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _statusCard(),
                    const SizedBox(height: 18),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final settings = _settingsCard();
                        final guide = _guideCard();
                        if (constraints.maxWidth < 800) {
                          return Column(
                            children: [
                              settings,
                              const SizedBox(height: 14),
                              guide,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 5, child: settings),
                            const SizedBox(width: 18),
                            Expanded(flex: 4, child: guide),
                          ],
                        );
                      },
                    ),
                    if (model.notice != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xffe7efe9),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: SelectableText(model.notice!),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _logsCard(),
                    const SizedBox(height: 12),
                    const Text(
                      'UxPlay 1.73.7 + GStreamer  ·  GPLv3 开源  ·  仅同局域网，暂不支持 DRM 内容',
                      style: TextStyle(fontSize: 12, color: Color(0xff68756e)),
                    ),
                  ],
                ),
              ),
            ),
          ),
  );

  Widget _card(Widget child) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: Color(0xffdee5e0)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      child: child,
    ),
  );

  Widget _statusCard() => _card(
    Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: model.status == 'error'
                ? Colors.orange
                : model.active
                ? const Color(0xff238c6f)
                : Colors.grey,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(model.message, key: const Key('statusMessage')),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        if (model.active)
          OutlinedButton.icon(
            key: const Key('stop'),
            onPressed: model.canStop ? model.stop : null,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('停止接收'),
          )
        else
          FilledButton.icon(
            key: const Key('start'),
            onPressed: model.canStart
                ? () => model.start(_name.text, _path.text)
                : null,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('启动接收'),
          ),
      ],
    ),
  );

  Widget _settingsCard() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '接收器设置',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 15),
        TextField(
          key: const Key('receiverName'),
          controller: _name,
          enabled: model.editable,
          decoration: const InputDecoration(
            labelText: '设备名',
            helperText: '显示在 iPhone 的“屏幕镜像”列表中',
          ),
          onSubmitted: (_) => model.save(_name.text, _path.text),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton(
              onPressed: model.editable
                  ? () => model.save(_name.text, _path.text)
                  : null,
              child: const Text('保存设置'),
            ),
            const SizedBox(width: 10),
            TextButton(
              key: const Key('check'),
              onPressed: model.editable ? () => model.check(_path.text) : null,
              child: const Text('检查依赖'),
            ),
            if (model.busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        ExpansionTile(
          title: const Text('高级：接收核心路径', style: TextStyle(fontSize: 13)),
          tilePadding: EdgeInsets.zero,
          children: [
            TextField(
              key: const Key('receiverPath'),
              controller: _path,
              enabled: model.editable,
              decoration: const InputDecoration(
                labelText: 'UxPlay 绝对路径（可选）',
                helperText: '留空使用随应用构建的核心；需本项目状态补丁',
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _guideCard() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '画面预览',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              key: const Key('expandPreview'),
              tooltip: '全屏预览',
              onPressed: () => setState(() => _previewExpanded = true),
              icon: const Icon(Icons.fullscreen),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            key: const Key('videoPreview'),
            height: 240,
            width: double.infinity,
            color: const Color(0xff101a17),
            alignment: Alignment.center,
            child: _videoSurface(),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Mac 和 iPhone 连接同一局域网。启动接收后，在 iPhone 控制中心 → 屏幕镜像 → 选择设备名。',
          style: TextStyle(fontSize: 13, color: Color(0xff5b6964), height: 1.5),
        ),
        const SizedBox(height: 8),
        const Text(
          '声音由 Mac 播放；请允许系统的局域网访问提示。',
          style: TextStyle(fontSize: 12, color: Color(0xff68756e)),
        ),
      ],
    ),
  );

  Widget _videoSurface() => model.hasVideo
      ? AspectRatio(
          aspectRatio: model.videoWidth / model.videoHeight,
          child: Texture(textureId: model.textureId),
        )
      : Padding(
          padding: const EdgeInsets.all(22),
          child: Text(
            '等待 iPhone 画面',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xffb6c9be)),
          ),
        );

  Widget _expandedPreview() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          setState(() => _previewExpanded = false),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        backgroundColor: const Color(0xff101a17),
        body: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('collapsePreview'),
                    tooltip: '退出全屏预览（Esc）',
                    color: Colors.white,
                    onPressed: () => setState(() => _previewExpanded = false),
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                  Expanded(
                    child: Text(
                      model.message,
                      style: const TextStyle(color: Color(0xffb6c9be)),
                    ),
                  ),
                  if (model.canStop)
                    TextButton(
                      onPressed: model.stop,
                      child: const Text('停止接收'),
                    ),
                ],
              ),
              Expanded(child: Center(child: _videoSurface())),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _logsCard() => Container(
    decoration: BoxDecoration(
      color: const Color(0xff182620),
      borderRadius: BorderRadius.circular(14),
    ),
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
    child: Column(
      children: [
        Row(
          children: [
            const Text(
              '接收日志',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${model.logs.length} / 300',
              style: const TextStyle(color: Color(0xffa1b8aa), fontSize: 12),
            ),
            const Spacer(),
            TextButton(
              onPressed: model.logs.isEmpty
                  ? null
                  : () => Clipboard.setData(ClipboardData(text: model.logText)),
              child: const Text(
                '复制',
                style: TextStyle(color: Color(0xffb6d3c0)),
              ),
            ),
            TextButton(
              onPressed: model.clearLogs,
              child: const Text(
                '清空',
                style: TextStyle(color: Color(0xffb6d3c0)),
              ),
            ),
          ],
        ),
        SizedBox(
          height: 160,
          child: model.logs.isEmpty
              ? const Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    '启动接收器后，运行日志会显示在这里。',
                    style: TextStyle(color: Color(0xffa1b8aa)),
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  itemCount: model.logs.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: SelectableText(
                      model.logs[model.logs.length - 1 - index].display,
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11,
                        height: 1.5,
                        color: Color(0xffc8ddd0),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    ),
  );
}
