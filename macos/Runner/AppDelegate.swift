// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS
import IOKit.pwr_mgt

@main
class AppDelegate: FlutterAppDelegate, NSMenuItemValidation {
  let receiver = ReceiverBridge()
  var keepRunningWithoutWindow = false
  private var desktopLaunchSource: DesktopLaunchSource?
  private var snapshot: [String: Any] = [:]
  private var displayAssertion: IOPMAssertionID = 0
  private var hasDisplayAssertion = false
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
  func preference(_ key: String, default fallback: Bool) -> Bool { snapshot[key] as? Bool ?? fallback }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // The launch Apple event is only current during this callback. Capture it
    // before Flutter or an asynchronous startup handshake can replace it.
    desktopLaunchSource = DesktopLaunchSource(appleEvent: NSAppleEventManager.shared().currentAppleEvent)
    super.applicationDidFinishLaunching(notification)
    configureApplication()
  }

  func configureApplication() {
    if let source = desktopLaunchSource { window?.setDesktopLaunchSource(source) }
    installMainMenu()
    receiver.onSnapshot = { [weak self] value in self?.update(value) }
  }

  private func update(_ value: [String: Any]) {
    snapshot = value
    if playing && !hasDisplayAssertion {
      hasDisplayAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Flutter AirPlay mirroring" as CFString, &displayAssertion) == kIOReturnSuccess
    } else if !playing && hasDisplayAssertion { IOPMAssertionRelease(displayAssertion); hasDisplayAssertion = false }
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
    let fullscreen = NSMenuItem(title: text("enterFullscreen"), action: #selector(toggleFullscreen), keyEquivalent: "f")
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

  @objc func openApp() {
    window?.showApp()
  }
  @objc func openSettings() { window?.openFlutterPanel("openSettings") }
  @objc func openLogs() { window?.openFlutterPanel("openLogs") }
  @objc func toggleReceiver() { window?.openFlutterPanel("toggleReceiver") }
  @objc func disconnectSession() { window?.openFlutterPanel("disconnectSession") }
  @objc func toggleOnTop() { window?.openFlutterPanel("toggleOnTop") }
  @objc func actualSize() { window?.openFlutterPanel("actualSize") }
  @objc func fitScreen() { window?.openFlutterPanel("fitScreen") }
  @objc func minimize() { window?.openFlutterPanel("minimizeWindow") }
  @objc func zoom() { window?.openFlutterPanel("toggleMaximize") }
  @objc func toggleFullscreen() { window?.openFlutterPanel("toggleFullscreen") }
  @objc func closeWindow() { window?.close() }
  @objc func bringAll() { openApp(); NSApp.arrangeInFront(nil) }
  @objc func about() { NSApp.orderFrontStandardAboutPanel(nil) }
  @objc func hideApp() { NSApp.hide(nil) }
  @objc func hideOthers() { NSApp.hideOtherApplications(nil) }
  @objc func showAll() { NSApp.unhideAllApplications(nil) }
  @objc func instructions() {
    openApp()
    let alert = NSAlert(); alert.messageText = text("instructions")
    alert.informativeText = [text("sameWifi"), text("openControlCenter"), text("tapMirroring"), text("selectReceiver").replacingOccurrences(of: "{name}", with: snapshot["name"] as? String ?? "Flutter AirPlay")].joined(separator: "\n")
    if let window = window { alert.beginSheetModal(for: window) }
  }
  @objc func quitApp() { NSApp.terminate(nil) }
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openApp(); return true }
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !keepRunningWithoutWindow }
  override func applicationWillTerminate(_ notification: Notification) {
    if hasDisplayAssertion { IOPMAssertionRelease(displayAssertion) }
    receiver.dispose(); super.applicationWillTerminate(notification)
  }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
