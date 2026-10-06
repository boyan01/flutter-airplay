import 'package:nativeapi/nativeapi.dart' as native;

class FakeWindow implements native.Window {
  FakeWindow({List<String>? calls}) : calls = calls ?? [];
  final List<String> calls;
  bool fullscreen = false, maximized = false;
  @override
  bool isAlwaysOnTop = false;
  native.Size _size = const native.Size(width: 440, height: 560);
  @override
  native.Point position = const native.Point(x: 100, y: 100);
  @override
  native.Size minimumSize = const native.Size(width: 360, height: 480);
  @override
  double aspectRatio = 0;
  @override
  native.Size get contentSize => _size;
  @override
  set contentSize(native.Size value) => _size = value;
  @override
  native.Size get size => _size;
  @override
  native.Rectangle get bounds => native.Rectangle(
    x: position.x,
    y: position.y,
    width: _size.width,
    height: _size.height,
  );

  @override
  bool get isFullScreen => fullscreen;
  @override
  set isFullScreen(bool value) {
    fullscreen = value;
    calls.add('fullscreen:$value');
  }

  @override
  bool get isMaximized => maximized;
  @override
  void maximize() {
    maximized = true;
    calls.add('maximize');
  }

  @override
  void unmaximize() {
    maximized = false;
    calls.add('unmaximize');
  }

  @override
  void minimize() => calls.add('minimize');
  @override
  void startDragging() => calls.add('startDragging');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
