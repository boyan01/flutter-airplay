// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS
import IOKit.pwr_mgt

@main
class AppDelegate: FlutterAppDelegate, NSMenuDelegate, NSMenuItemValidation {
  let receiver = ReceiverBridge()
  private var statusItem: NSStatusItem?
  private var snapshot: [String: Any] = [:]
  private var displayAssertion: IOPMAssertionID = 0
  private var hasDisplayAssertion = false
  private var wasPlaying = false
  private var openedForSession = false
  private var autoHide: DispatchWorkItem?
  private var iconPulse: Timer?
  private var pulseVisible = true
  private lazy var strings: [String: String] = {
    let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
    let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/App.framework/Resources/flutter_assets/lib/l10n/app_\(language).arb")
    guard let data = try? Data(contentsOf: url), let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return values.compactMapValues { $0 as? String }
  }()
  private var window: MainFlutterWindow? { mainFlutterWindow as? MainFlutterWindow }
  private var playing: Bool { (snapshot["videoWidth"] as? Int ?? 0) > 0 && (snapshot["videoHeight"] as? Int ?? 0) > 0 }
  private var active: Bool { ["checking", "starting", "waiting", "streaming", "stopping"].contains(snapshot["status"] as? String ?? "stopped") }
  private var transitioning: Bool { ["checking", "starting", "stopping"].contains(snapshot["status"] as? String ?? "stopped") }
  func text(_ key: String) -> String { strings[key] ?? key }
  func preference(_ key: String, default fallback: Bool) -> Bool { snapshot[key] as? Bool ?? UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    configureApplication()
  }

  func configureApplication() {
    installMainMenu()
    guard statusItem == nil else { return }
    receiver.onSnapshot = { [weak self] value in self?.update(value) }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu(); menu.delegate = self; statusItem?.menu = menu
    receiver.nativeAction { _ in }
  }

  private func update(_ value: [String: Any]) {
    snapshot = value
    let connected = snapshot["status"] as? String == "streaming"
    let symbol = snapshot["status"] as? String == "error" ? "exclamationmark.triangle" : connected ? "airplayvideo.circle.fill" : "airplayvideo"
    var image = NSImage(systemSymbolName: symbol, accessibilityDescription: text("receive"))
    if playing { image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) }
    image?.isTemplate = !playing; statusItem?.button?.image = image
    statusItem?.button?.appearsDisabled = !active
    let pulse = transitioning || (connected && !playing)
    if pulse && iconPulse == nil {
      iconPulse = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
        guard let self = self else { return }
        self.pulseVisible.toggle(); self.statusItem?.button?.alphaValue = self.pulseVisible ? 1 : 0.4
      }
    } else if !pulse { iconPulse?.invalidate(); iconPulse = nil; statusItem?.button?.alphaValue = 1 }
    if playing && !hasDisplayAssertion {
      hasDisplayAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Flutter AirPlay mirroring" as CFString, &displayAssertion) == kIOReturnSuccess
    } else if !playing && hasDisplayAssertion { IOPMAssertionRelease(displayAssertion); hasDisplayAssertion = false }
    if playing && !wasPlaying {
      autoHide?.cancel()
      if window?.isVisible == false && preference("showOnConnect", default: true) {
        openedForSession = true; showWindow(userInitiated: false)
      }
      if preference("fullscreenOnConnect", default: false) { window?.setFullscreen(true) }
    } else if !playing && wasPlaying && openedForSession {
      let task = DispatchWorkItem { [weak self] in
        guard let self = self, !self.playing, self.openedForSession else { return }
        self.hideWindow(disconnect: false)
      }
      autoHide = task; DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }
    window?.level = playing && preference("alwaysOnTop", default: false) ? .floating : .normal
    wasPlaying = playing
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard menu === statusItem?.menu else { return }
    menu.removeAllItems()
    menu.addItem(NSMenuItem(title: snapshot["name"] as? String ?? "Flutter AirPlay", action: nil, keyEquivalent: ""))
    let client = (snapshot["clientName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
    let state = snapshot["status"] as? String ?? "stopped"
    let label = playing ? text("clientPlaying").replacingOccurrences(of: "{name}", with: client)
      : state == "streaming" ? text("clientConnecting").replacingOccurrences(of: "{name}", with: client)
      : state == "error" ? "⚠ \(snapshot["message"] as? String ?? text("unavailable"))"
      : transitioning ? text("starting") : active ? text("discoverable") : text("off")
    menu.addItem(NSMenuItem(title: label, action: nil, keyEquivalent: ""))
    if playing { menu.addItem(NSMenuItem(title: "\(snapshot["videoWidth"] ?? 0) × \(snapshot["videoHeight"] ?? 0)", action: nil, keyEquivalent: "")) }
    menu.addItem(.separator())
    if playing {
      menu.addItem(item("showPlayer", #selector(openApp), ""))
      menu.addItem(item("disconnect", #selector(disconnectSession), ""))
    }
    let receive = item("receive", #selector(toggleReceiver), "r"); receive.state = active ? .on : .off; menu.addItem(receive)
    if state == "error" { menu.addItem(item("retry", #selector(toggleReceiver), "")) }
    menu.addItem(.separator())
    if !playing { menu.addItem(item("openApp", #selector(openApp), "")) }
    menu.addItem(item("settings", #selector(openSettings), ",")); menu.addItem(item("logs", #selector(openLogs), "l"))
    menu.addItem(.separator()); menu.addItem(item("quitApp", #selector(quitApp), "q"))
  }

  private func item(_ key: String, _ action: Selector, _ shortcut: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let value = NSMenuItem(title: text(key), action: action, keyEquivalent: shortcut)
    value.target = self; value.keyEquivalentModifierMask = modifiers; return value
  }
  private func installMainMenu() {
    let main = NSMenu()
    func submenu(_ title: String, _ children: [NSMenuItem]) {
      let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title); children.forEach { menu.addItem($0) }; parent.submenu = menu; main.addItem(parent)
    }
    submenu("Flutter AirPlay", [item("about", #selector(about), ""), item("settings", #selector(openSettings), ","), .separator(),
      item("hideApp", #selector(hideApp), "h"), item("hideOthers", #selector(hideOthers), "h", modifiers: [.option, .command]),
      item("showAll", #selector(showAll), ""), .separator(), item("quitApp", #selector(quitApp), "q")])
    let edit = [("undo", "undo:", "z"), ("redo", "redo:", "Z"), ("cut", "cut:", "x"), ("copy", "copy:", "c"), ("paste", "paste:", "v"), ("selectAll", "selectAll:", "a")].map { key, selector, shortcut -> NSMenuItem in
      NSMenuItem(title: text(key), action: NSSelectorFromString(selector), keyEquivalent: shortcut)
    }
    submenu(text("editMenu"), edit)
    submenu(text("receiverMenu"), [item("receive", #selector(toggleReceiver), "r"), item("disconnect", #selector(disconnectSession), ".")])
    let fullscreen = NSMenuItem(title: text("enterFullscreen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fullscreen.keyEquivalentModifierMask = [.control, .command]
    submenu(text("viewMenu"), [fullscreen, item("actualSize", #selector(actualSize), "0"), item("fitScreen", #selector(fitScreen), "9"), .separator(),
      item("alwaysOnTop", #selector(toggleOnTop), "t", modifiers: [.option, .command])])
    submenu(text("windowMenu"), [item("minimize", #selector(minimize), "m"), item("zoom", #selector(zoom), ""), item("close", #selector(closeWindow), "w"),
      .separator(), item("bringAll", #selector(bringAll), "")])
    submenu(text("helpMenu"), [item("logs", #selector(openLogs), "l"), item("instructions", #selector(instructions), "")])
    NSApp.mainMenu = main
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(toggleReceiver) { menuItem.state = active ? .on : .off; return !transitioning }
    if [#selector(disconnectSession), #selector(actualSize), #selector(fitScreen), #selector(toggleOnTop)].contains(menuItem.action) {
      if menuItem.action == #selector(toggleOnTop) { menuItem.state = preference("alwaysOnTop", default: false) ? .on : .off }
      return playing
    }
    return true
  }

  private func showWindow(userInitiated: Bool) {
    if userInitiated { autoHide?.cancel(); openedForSession = false }
    NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  func hideWindow(disconnect: Bool = true) {
    autoHide?.cancel(); openedForSession = false
    if disconnect && snapshot["status"] as? String == "streaming" { receiver.nativeAction { $0.disconnect() } }
    window?.orderOut(nil); NSApp.setActivationPolicy(.accessory)
  }
  @objc func openApp() { showWindow(userInitiated: true) }
  @objc func openSettings() { showWindow(userInitiated: true); window?.openFlutterPanel("openSettings") }
  @objc func openLogs() { showWindow(userInitiated: true); window?.openFlutterPanel("openLogs") }
  @objc func toggleReceiver() {
    guard !transitioning else { return }
    receiver.nativeAction { host in
      let value = host.snapshot()
      if ["waiting", "streaming", "starting", "checking"].contains(value["status"] as? String ?? "") { host.stop() }
      else { try host.start(name: value["name"] as? String ?? "Flutter AirPlay", path: value["path"] as? String ?? "") }
    }
  }
  @objc func disconnectSession() { receiver.nativeAction { $0.disconnect() } }
  @objc func toggleOnTop() {
    let next = !preference("alwaysOnTop", default: false)
    receiver.nativeAction { host in let value = host.snapshot(); try host.save(name: value["name"] as? String ?? "", path: value["path"] as? String ?? "", options: ["alwaysOnTop": next]) }
  }
  @objc func actualSize() { window?.resizePlayer(actualSize: true) }
  @objc func fitScreen() { window?.resizePlayer(actualSize: false) }
  @objc func minimize() { window?.miniaturize(nil) }
  @objc func zoom() { window?.zoom(nil) }
  @objc func closeWindow() { window?.close() }
  @objc func bringAll() { showWindow(userInitiated: true); NSApp.arrangeInFront(nil) }
  @objc func about() { NSApp.orderFrontStandardAboutPanel(nil) }
  @objc func hideApp() { NSApp.hide(nil) }
  @objc func hideOthers() { NSApp.hideOtherApplications(nil) }
  @objc func showAll() { NSApp.unhideAllApplications(nil) }
  @objc func instructions() {
    showWindow(userInitiated: true)
    let alert = NSAlert(); alert.messageText = text("instructions")
    alert.informativeText = [text("sameWifi"), text("openControlCenter"), text("tapMirroring"), text("selectReceiver").replacingOccurrences(of: "{name}", with: snapshot["name"] as? String ?? "Flutter AirPlay")].joined(separator: "\n")
    if let window = window { alert.beginSheetModal(for: window) }
  }
  @objc func quitApp() { NSApp.terminate(nil) }
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(userInitiated: true); return true }
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !preference("keepInMenuBar", default: true) }
  override func applicationWillTerminate(_ notification: Notification) {
    autoHide?.cancel(); iconPulse?.invalidate()
    if hasDisplayAssertion { IOPMAssertionRelease(displayAssertion) }
    receiver.dispose(); super.applicationWillTerminate(notification)
  }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
