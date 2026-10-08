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

// Run AppKit layout after Dart has yielded. Synchronous FFI resizing can wait
// for a Flutter frame that the same Dart stack cannot produce yet.
private final class WindowResizeAnimation: NSAnimation {
  weak var window: NSWindow?
  let from: NSRect
  let target: NSRect

  init(window: NSWindow, target: NSRect, duration: TimeInterval) {
    self.window = window
    self.from = window.frame
    self.target = target
    super.init(duration: duration, animationCurve: .easeOut)
    animationBlockingMode = .nonblocking
    frameRate = Float(window.screen?.maximumFramesPerSecond ?? 60)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var currentProgress: NSAnimation.Progress {
    get { super.currentProgress }
    set {
      guard let window = window, window.isVisible, !window.isMiniaturized, !window.isZoomed,
            !window.styleMask.contains(.fullScreen), !window.inLiveResize else {
        stop(); return
      }
      super.currentProgress = newValue
      let t = CGFloat(currentValue)
      window.setFrame(NSRect(
        x: from.minX + (target.minX - from.minX) * t,
        y: from.minY + (target.minY - from.minY) * t,
        width: from.width + (target.width - from.width) * t,
        height: from.height + (target.height - from.height) * t), display: true)
    }
  }
}

class MainFlutterWindow: NSWindow, NSAnimationDelegate {
  private var resizeAnimation: WindowResizeAnimation?
  private var resizeCompletion: ((Bool) -> Void)?
  private var resizeRevision = 0
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
    cancelWindowResize()
    if hideOnClose {
      openFlutterPanel("closeRequested")
    } else {
      (NSApp.delegate as? AppDelegate)?.receiver.dispose()
      super.close()
    }
  }

  override func orderOut(_ sender: Any?) {
    cancelWindowResize()
    super.orderOut(sender)
  }

  func resizeWindow(to target: NSRect, duration: TimeInterval, completion: @escaping (Bool) -> Void) {
    cancelWindowResize()
    guard isVisible, !isMiniaturized, !isZoomed,
          !styleMask.contains(.fullScreen), !inLiveResize else {
      completion(false); return
    }
    if duration == 0 {
      setFrame(target, display: true)
      completion(true)
      return
    }
    let animation = WindowResizeAnimation(window: self, target: target, duration: duration)
    resizeAnimation = animation
    resizeCompletion = completion
    animation.delegate = self
    animation.start()
  }

  func cancelWindowResize() {
    resizeRevision += 1
    let animation = resizeAnimation
    let completion = resizeCompletion
    resizeAnimation = nil
    resizeCompletion = nil
    animation?.stop()
    completion?(false)
  }

  func animationDidEnd(_ animation: NSAnimation) {
    guard animation === resizeAnimation else { return }
    let completion = resizeCompletion
    resizeAnimation = nil
    resizeCompletion = nil
    completion?(true)
  }

  func animationDidStop(_ animation: NSAnimation) {
    if animation === resizeAnimation { cancelWindowResize() }
  }

  override func awakeFromNib() {
    let controller = FlutterViewController()
    controller.backgroundColor = .clear
    let surface = VideoSurface(frame: contentView?.bounds ?? .zero)
    let container = NSViewController()
    container.view = surface
    container.addChild(controller)
    controller.view.frame = surface.bounds
    controller.view.autoresizingMask = [.width, .height]
    surface.addSubview(controller.view)
    // Hover reveals controls without activating the window or changing click handling.
    controller.mouseTrackingMode = .always
    styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
    configureContentWindow()
    contentViewController = container
    initialFirstResponder = controller.view
    setContentSize(NSSize(width: 440, height: 560))
    minSize = NSSize(width: 360, height: 480)
    center()
    RegisterGeneratedPlugins(registry: controller)
    (NSApp.delegate as? AppDelegate)?.receiver.install(on: controller.engine.binaryMessenger, video: surface)
    updateReceiverDisplay()
    presentation = FlutterMethodChannel(name: "tech.soit.flutterairplay/window", binaryMessenger: controller.engine.binaryMessenger)
    presentation?.setMethodCallHandler { [weak self] call, result in
      if let self = self {
        switch call.method {
        case "resizeWindow":
          guard let values = call.arguments as? [String: NSNumber],
                let x = values["x"]?.doubleValue, let y = values["y"]?.doubleValue,
                let width = values["width"]?.doubleValue, let height = values["height"]?.doubleValue,
                let duration = values["duration"]?.doubleValue,
                [x, y, width, height, duration].allSatisfy({ $0.isFinite }),
                width > 0, height > 0, duration >= 0, duration <= 1,
                let primary = NSScreen.screens.first else {
            result(FlutterError(code: "invalid_arguments", message: "resizeWindow requires finite bounds and a duration from 0 to 1 second", details: nil)); return
          }
          // Match nativeapi's desktop coordinates, including secondary screens.
          let target = NSRect(x: x, y: primary.frame.height - y - height, width: width, height: height)
          self.cancelWindowResize()
          let revision = self.resizeRevision
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.resizeRevision == revision else { result(false); return }
            self.resizeWindow(to: target, duration: duration) { result($0) }
          }
          return
        case "cancelWindowResize": self.cancelWindowResize(); result(nil); return
        case "titlebarDoubleClick": self.performTitlebarDoubleClick(); result(nil); return
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

  func performTitlebarDoubleClick(action: String? = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
    // Keep the system's titlebar policy separate from the explicit fullscreen button.
    guard !styleMask.contains(.fullScreen) else { return }
    switch action?.lowercased() {
    case "minimize": performMiniaturize(nil)
    case "none": break
    default:
      // AppKit does not expose its newer Fill action publicly. Use native zoom
      // rather than private selectors or maintaining a second geometry policy.
      performZoom(nil)
    }
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
        self?.cancelWindowResize()
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
