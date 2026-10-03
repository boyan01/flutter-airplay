// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const AirPlayApp());

class AirPlayApp extends StatelessWidget {
  const AirPlayApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flutter AirPlay',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff8dc6ff),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: const ReceiverPage(),
  );
}

class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key});
  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  static const control = MethodChannel('flutter_airplay/control');
  static const events = EventChannel('flutter_airplay/events');
  final name = TextEditingController(text: 'Flutter AirPlay Android');
  StreamSubscription<dynamic>? subscription;
  int? texture;
  double width = 1920, height = 1080;
  String status = '正在启动接收器', phase = 'starting';
  bool busy = false, active = false;
  @override
  void initState() {
    super.initState();
    subscription = events.receiveBroadcastStream().listen(
      (dynamic event) {
        if (!mounted) return;
        final value = Map<String, dynamic>.from(event as Map);
        setState(() {
          if (value['message'] != null) status = value['message'] as String;
          if (value['state'] != null) phase = value['state'] as String;
          if (value['width'] != null) {
            width = (value['width'] as num).toDouble();
          }
          if (value['height'] != null) {
            height = (value['height'] as num).toDouble();
          }
          if (phase == 'stopped') {
            active = false;
            texture = null;
          }
        });
      },
      onError: (Object error) {
        if (mounted) {
          setState(() {
            status = '$error';
            phase = 'error';
          });
        }
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => start());
  }

  Future<void> start() async {
    setState(() {
      busy = true;
      status = '正在启动接收器';
      phase = 'starting';
    });
    try {
      final value = await control.invokeMapMethod<String, dynamic>('start', {
        'name': name.text,
      });
      if (!mounted) return;
      setState(() {
        texture = value!['textureId'] as int;
        active = true;
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          status = error.message ?? '启动失败';
          phase = 'error';
          active = false;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> stop() async {
    setState(() => busy = true);
    try {
      await control.invokeMethod<void>('stop');
      if (mounted) {
        setState(() {
          active = false;
          texture = null;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          status = error.message ?? '停止失败';
          phase = 'error';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xff10151c),
      appBar: AppBar(
        title: const Text('Flutter AirPlay'),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: '开源许可',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showLicense(context),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '将 iPhone 屏幕投到这里',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '两台设备连接同一个 Wi-Fi。在 iPhone 控制中心打开「屏幕镜像」，选择下方接收器名称。',
                      ),
                      const SizedBox(height: 24),
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xff1b2430),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          children: [
                            Icon(
                              phase == 'error'
                                  ? Icons.error_outline
                                  : active
                                  ? Icons.wifi_tethering
                                  : Icons.cast,
                              color: phase == 'error'
                                  ? colors.error
                                  : colors.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(status)),
                            if (busy)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          color: Colors.black,
                          constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight * .62,
                          ),
                          child: AspectRatio(
                            aspectRatio: width / height,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                if (texture != null)
                                  Texture(textureId: texture!),
                                if (phase != 'playing')
                                  const Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.airplay,
                                        size: 48,
                                        color: Colors.white38,
                                      ),
                                      SizedBox(height: 12),
                                      Text(
                                        '等待屏幕镜像',
                                        style: TextStyle(color: Colors.white54),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: name,
                        enabled: !active && !busy,
                        maxLength: 48,
                        decoration: const InputDecoration(
                          labelText: '接收器名称',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: busy
                              ? null
                              : active
                              ? stop
                              : start,
                          icon: Icon(
                            active
                                ? Icons.stop_circle_outlined
                                : Icons.play_arrow,
                          ),
                          label: Text(active ? '停止接收' : '启动接收'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '接收期间保持此应用打开。视频和音频在这台 Android 设备上播放。',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void showLicense(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('开源软件'),
        content: const SingleChildScrollView(
          child: Text(
            'Flutter AirPlay Android 使用 UxPlay 接收核心，以及 jqssun/android-airplay-server 的 Android 视频和音频实现。\n\n应用遵循 GPL-3.0；完整源码和依赖许可随项目提供。\n\n项目：github.com/boyan01/flutter-airplay\n参考：github.com/jqssun/android-airplay-server\n音频：Oboe、FFmpeg\n加密：OpenSSL\n协议数据：libplist',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
