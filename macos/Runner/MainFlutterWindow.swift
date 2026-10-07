// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS
import ServiceManagement

enum DesktopLaunchSource {
  case manual, loginItem

  init(appleEvent: NSAppleEventDescriptor?) {
    self = appleEvent?.eventID == kAEOpenApplication &&
      appleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
      ? .loginItem : .manual
  }
}

class MainFlutterWindow: NSWindow {
  private var presentation: FlutterMethodChannel?
  var hideOnClose: Bool {
    get { (NSApp.delegate as? AppDelegate)?.keepRunningWithoutWindow ?? false }
    set { (NSApp.delegate as? AppDelegate)?.keepRunningWithoutWindow = newValue }
  }
  private(set) var desktopReady = false
  private var desktopLaunchSource: DesktopLaunchSource?
  private var pendingTrayStartup = false
  private var startupFinished = false
  private var reopenRequested = false
  private var startupTimeout: DispatchWorkItem?
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
        case "finishDesktopStartup":
          guard let trayAvailable = call.arguments as? Bool else {
            result(FlutterError(code: "invalid_arguments", message: "finishDesktopStartup requires a boolean", details: nil)); return
          }
          result(self.finishDesktopStartup(trayAvailable: trayAvailable)); return
        case "getLaunchAtLogin", "setLaunchAtLogin":
          self.handleLaunchAtLogin(call, result: result); return
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
    scheduleStartupTimeout()
    installPresentationObservers()
    super.awakeFromNib()
    configureContentWindow()
    // Hidden windows never reach viewWillAppear, where Flutter normally starts
    // its engine. Start after installing every host handler and plugin instead.
    _ = controller.engine.run(withEntrypoint: nil)
    DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.configureApplication() }
  }

  private func scheduleStartupTimeout() {
    let timeout = DispatchWorkItem { [weak self] in _ = self?.finishDesktopStartup(trayAvailable: false) }
    startupTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
  }

  func setDesktopLaunchSource(_ source: DesktopLaunchSource) {
    guard desktopLaunchSource == nil else { return }
    desktopLaunchSource = source
    if pendingTrayStartup { finishDesktopStartup(trayAvailable: true) }
  }

  func showApp() {
    if !startupFinished { reopenRequested = true }
    // Keep OS reopen usable even when Dart initialization failed after its
    // early desktopReady handshake. Dart still resets its auto-hide policy.
    NSApp.setActivationPolicy(.regular)
    if isMiniaturized { deminiaturize(nil) }
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if startupFinished && desktopReady { openFlutterPanel("openApp") }
  }

  @discardableResult
  func finishDesktopStartup(trayAvailable: Bool) -> Bool {
    guard !startupFinished || !trayAvailable else { return true }
    // awakeFromNib starts Flutter before applicationDidFinishLaunching captures
    // the launch event. Wait for that source before choosing silent startup,
    // but keep the native watchdog/tray-failure fallback independent of it.
    if trayAvailable && desktopLaunchSource == nil {
      pendingTrayStartup = true
      return true
    }
    pendingTrayStartup = false
    startupFinished = true
    startupTimeout?.cancel()
    startupTimeout = nil
    if !trayAvailable || desktopLaunchSource != .loginItem || reopenRequested {
      if !trayAvailable { hideOnClose = false }
      NSApp.setActivationPolicy(.regular)
      makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      if desktopReady { openFlutterPanel("openApp") }
    } else if !isVisible {
      NSApp.setActivationPolicy(.accessory)
    }
    return trayAvailable
  }

  private func handleLaunchAtLogin(_ call: FlutterMethodCall, result: FlutterResult) {
    guard #available(macOS 13.0, *) else {
      result(FlutterError(code: "unsupported",
                          message: "Login startup requires macOS 13 or later", details: nil))
      return
    }
    let service = SMAppService.mainApp
    do {
      if call.method == "setLaunchAtLogin" {
        guard let enabled = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_arguments",
                              message: "setLaunchAtLogin requires a boolean", details: nil))
          return
        }
        if enabled {
          // An approval-pending item is already registered. Only System Settings
          // can approve it; do not reregister or claim it is enabled.
          if service.status != .enabled && service.status != .requiresApproval {
            try service.register()
          }
        } else if service.status != .notRegistered {
          // requiresApproval is also a registered item and must be removable.
          try service.unregister()
        }
      }
      if service.status == .requiresApproval {
        result(FlutterError(code: "approval_required",
                            message: "Approve Flutter AirPlay in System Settings Login Items", details: nil))
      } else {
        result(service.status == .enabled)
      }
    } catch {
      let nativeError = error as NSError
      result(FlutterError(code: "launch_at_login_error", message: error.localizedDescription,
                          details: ["domain": nativeError.domain, "code": nativeError.code]))
    }
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
    startupTimeout?.cancel()
    for observer in presentationObservers { NotificationCenter.default.removeObserver(observer) }
  }
}
