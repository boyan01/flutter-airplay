// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var presentation: FlutterMethodChannel?
  private var fullscreenTarget: Bool?
  private var fullscreenTransition = false
  private var presentationObservers: [NSObjectProtocol] = []

  override func close() {
    (NSApp.delegate as? AppDelegate)?.receiver.dispose()
    super.close()
  }

  override func awakeFromNib() {
    let controller = FlutterViewController()
    contentViewController = controller
    setContentSize(NSSize(width: 1000, height: 740))
    minSize = NSSize(width: 480, height: 480)
    center()
    RegisterGeneratedPlugins(registry: controller)
    (NSApp.delegate as? AppDelegate)?.receiver.install(on: controller.engine.binaryMessenger, textures: controller.engine)
    presentation = FlutterMethodChannel(name: "org.flutterairplay/window", binaryMessenger: controller.engine.binaryMessenger)
    presentation?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setFullscreen" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self, let arguments = call.arguments as? [String: Any],
            let fullscreen = arguments["fullscreen"] as? Bool else {
        result(FlutterError(code: "window_error", message: "无法读取全屏请求", details: nil))
        return
      }
      self.fullscreenTarget = fullscreen
      self.updateFullscreen()
      result(nil)
    }
    let center = NotificationCenter.default
    for notification in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
      presentationObservers.append(center.addObserver(forName: notification, object: self, queue: .main) { [weak self] _ in
        self?.fullscreenTransition = true
      })
    }
    for notification in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      presentationObservers.append(center.addObserver(forName: notification, object: self, queue: .main) { [weak self] _ in
        guard let self = self else { return }
        self.fullscreenTransition = false
        self.updateFullscreen()
      })
    }
    super.awakeFromNib()
  }

  private func updateFullscreen() {
    guard !fullscreenTransition else { return }
    let actual = styleMask.contains(.fullScreen)
    if let target = fullscreenTarget, target != actual {
      fullscreenTransition = true
      toggleFullScreen(nil)
    } else {
      fullscreenTarget = nil
      presentation?.invokeMethod("fullscreenChanged", arguments: actual)
    }
  }

  deinit {
    for observer in presentationObservers { NotificationCenter.default.removeObserver(observer) }
  }
}
