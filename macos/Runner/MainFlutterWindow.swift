// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var presentation: FlutterMethodChannel?
  private var playerDimensions: NSSize?
  private var fullscreenTarget: Bool?
  private var fullscreenTransition = false
  private var presentationObservers: [NSObjectProtocol] = []

  override func close() {
    if let app = NSApp.delegate as? AppDelegate, app.preference("keepInMenuBar", default: true) {
      app.hideWindow()
    } else {
      (NSApp.delegate as? AppDelegate)?.receiver.dispose()
      super.close()
    }
  }

  override func awakeFromNib() {
    let controller = FlutterViewController()
    styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
    configureContentWindow()
    contentViewController = controller
    setContentSize(NSSize(width: 440, height: 560))
    minSize = NSSize(width: 360, height: 480)
    center()
    RegisterGeneratedPlugins(registry: controller)
    (NSApp.delegate as? AppDelegate)?.receiver.install(on: controller.engine.binaryMessenger, textures: controller.engine)
    presentation = FlutterMethodChannel(name: "org.flutterairplay/window", binaryMessenger: controller.engine.binaryMessenger)
    presentation?.setMethodCallHandler { [weak self] call, result in
      if call.method == "toggleFullscreen", let self = self {
        self.setFullscreen(!self.styleMask.contains(.fullScreen)); result(nil); return
      }
      if call.method == "exitFullscreen", let self = self {
        self.setFullscreen(false); result(nil); return
      }
      if let self = self {
        switch call.method {
        case "closeWindow": self.close(); result(nil); return
        case "minimizeWindow": self.miniaturize(nil); result(nil); return
        default: break
        }
      }
      if call.method == "setMode", let self = self,
         let arguments = call.arguments as? [String: Any] {
        let width = arguments["width"] as? Int ?? 0
        let height = arguments["height"] as? Int ?? 0
        let wasPlaying = self.playerDimensions != nil
        self.playerDimensions = arguments["mode"] as? String == "player" && width > 0 && height > 0
          ? NSSize(width: width, height: height) : nil
        self.applyMode(preserveArea: wasPlaying)
        result(nil)
        return
      }
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
    configureContentWindow()
    DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.configureApplication() }
  }

  private func configureContentWindow() {
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    if #available(macOS 11.0, *) { titlebarSeparatorStyle = .none }
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(type)?.isHidden = true
    }
  }

  private func applyMode(preserveArea: Bool = false) {
    configureContentWindow()
    guard !fullscreenTransition, !styleMask.contains(.fullScreen) else { return }
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
    let oldCenter = NSPoint(x: frame.midX, y: frame.midY)
    let size: NSSize
    if let dimensions = playerDimensions {
      let ratio = dimensions.width / dimensions.height
      let maxWidth = visible.width * 0.8
      let maxHeight = visible.height * 0.8
      let oldContent = contentRect(forFrameRect: frame).size
      let targetWidth = preserveArea ? sqrt(oldContent.width * oldContent.height * ratio) : maxWidth
      let width = min(targetWidth, min(maxWidth, maxHeight * ratio))
      size = NSSize(width: width, height: width / ratio)
      minSize = NSSize(width: 160, height: 160)
      contentAspectRatio = dimensions
      backgroundColor = .black
    } else {
      // Resize increments cancel aspect constraints; a zero ratio breaks fullscreen restoration.
      resizeIncrements = NSSize(width: 1, height: 1)
      minSize = NSSize(width: 360, height: 480)
      size = NSSize(width: 440, height: 560)
      backgroundColor = .windowBackgroundColor
    }
    var target = frameRect(forContentRect: NSRect(origin: .zero, size: size))
    target.origin = NSPoint(
      x: max(visible.minX, min(oldCenter.x - target.width / 2, visible.maxX - target.width)),
      y: max(visible.minY, min(oldCenter.y - target.height / 2, visible.maxY - target.height)))
    setFrame(target, display: true, animate: isVisible)
  }

  func openFlutterPanel(_ method: String) { presentation?.invokeMethod(method, arguments: nil) }
  func setFullscreen(_ target: Bool) { fullscreenTarget = target; updateFullscreen() }
  func resizePlayer(actualSize: Bool) {
    guard let dimensions = playerDimensions, !styleMask.contains(.fullScreen) else { return }
    if !actualSize { applyMode(); return }
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
    let scale = min(1, min(visible.width * 0.8 / dimensions.width, visible.height * 0.8 / dimensions.height))
    var target = frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: dimensions.width * scale, height: dimensions.height * scale)))
    target.origin = NSPoint(x: frame.midX - target.width / 2, y: frame.midY - target.height / 2)
    setFrame(target, display: true, animate: true)
  }

  private func updateFullscreen() {
    guard !fullscreenTransition else { return }
    let actual = styleMask.contains(.fullScreen)
    if let target = fullscreenTarget, target != actual {
      fullscreenTransition = true
      toggleFullScreen(nil)
    } else {
      fullscreenTarget = nil
      applyMode()
      presentation?.invokeMethod("fullscreenChanged", arguments: actual)
    }
  }

  deinit {
    for observer in presentationObservers { NotificationCenter.default.removeObserver(observer) }
  }
}
