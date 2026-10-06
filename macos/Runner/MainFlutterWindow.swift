// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var presentation: FlutterMethodChannel?
  var hideOnClose: Bool {
    get { (NSApp.delegate as? AppDelegate)?.keepRunningWithoutWindow ?? false }
    set { (NSApp.delegate as? AppDelegate)?.keepRunningWithoutWindow = newValue }
  }
  private(set) var desktopReady = false
  private var presentationObservers: [NSObjectProtocol] = []

  override func close() {
    if hideOnClose {
      openFlutterPanel("closeRequested")
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
    updateReceiverDisplay()
    presentation = FlutterMethodChannel(name: "tech.soit.flutterairplay/window", binaryMessenger: controller.engine.binaryMessenger)
    presentation?.setMethodCallHandler { [weak self] call, result in
      if let self = self {
        switch call.method {
        case "closeWindow": self.close(); result(nil); return
        case "quitApp": NSApp.terminate(nil); result(nil); return
        case "desktopReady": self.desktopReady = true; result(true); return
        case "getNativeWindowHandle":
          result(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())); return
        case "setClosePolicy": self.hideOnClose = call.arguments as? Bool ?? false; result(nil); return
        case "setDockVisible":
          NSApp.setActivationPolicy(call.arguments as? Bool == true ? .regular : .accessory)
          result(nil); return
        default: break
        }
      }
      result(FlutterMethodNotImplemented)
    }
    installPresentationObservers()
    super.awakeFromNib()
    configureContentWindow()
    DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.configureApplication() }
  }

  private func installPresentationObservers() {
    let center = NotificationCenter.default
    presentationObservers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.updateReceiverDisplay()
    })
    for notification in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
      presentationObservers.append(center.addObserver(forName: notification, object: self, queue: .main) { [weak self] _ in
        self?.openFlutterPanel("windowTransitionStarted")
      })
    }
    for notification in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      presentationObservers.append(center.addObserver(forName: notification, object: self, queue: .main) { [weak self] _ in
        guard let self = self else { return }
        self.presentation?.invokeMethod("windowStateChanged", arguments: ["fullscreen": self.styleMask.contains(.fullScreen), "maximized": self.isZoomed])
      })
    }
  }

  private func configureContentWindow() {
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    if #available(macOS 11.0, *) { titlebarSeparatorStyle = .none }
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(type)?.isHidden = true
    }
  }

  private func updateReceiverDisplay() {
    let display = (screen ?? NSScreen.main)?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    (NSApp.delegate as? AppDelegate)?.receiver.setDisplay(display?.uint32Value ?? CGMainDisplayID())
  }

  func openFlutterPanel(_ method: String) { presentation?.invokeMethod(method, arguments: nil) }

  deinit {
    for observer in presentationObservers { NotificationCenter.default.removeObserver(observer) }
  }
}
