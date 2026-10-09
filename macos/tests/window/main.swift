// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS

// Geometry and tray coverage lives in the real Flutter desktop integration test.
// This fixture checks host startup visibility, close and transition bridges.
final class TestReceiver {
  var disposed = false
  func dispose() { disposed = true }
  func install(on: FlutterBinaryMessenger, video: VideoSurface) {}
  func setDisplay(_ display: CGDirectDisplayID) {}
}
final class TestUpdates {
  func install(on: FlutterBinaryMessenger) {}
}
final class AppDelegate: NSObject, NSApplicationDelegate {
  let receiver = TestReceiver()
  let updates = TestUpdates()
  var keepRunningWithoutWindow = false
  func configureApplication() {}
}
func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {}
extension MainFlutterWindow {
  func installTestObservers() { installPresentationObservers() }
  func markDesktopReady() { desktopReady = true }
  func installTestStartupTimeout() { scheduleStartupTimeout() }
  func fireTestStartupTimeout() { startupTimeout?.perform() }
  var hasStartupTimeout: Bool { startupTimeout != nil }
  var hasFinishedStartup: Bool { startupFinished }
}
final class RecordingWindow: MainFlutterWindow {
  var actions: [String] = []
  override func openFlutterPanel(_ method: String) { actions.append(method) }
}
func require(_ condition: Bool, _ message: String) {
  if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let window = RecordingWindow(
  contentRect: NSRect(x: 200, y: 200, width: 440, height: 560),
  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
  backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.installTestObservers()
window.makeKeyAndOrderFront(nil)
window.hideOnClose = true
window.close()
require(window.isVisible && !delegate.receiver.disposed, "close-to-tray must defer hiding to Dart without disposing the receiver")
require(window.actions.contains("closeRequested"), "close must reach the shared policy")
print("PASS: close interception preserves the receiver")
NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
require(window.actions.contains("windowTransitionStarted"), "fullscreen transition must notify Dart before resizing")
print("PASS: fullscreen transition bridge")
NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
require(window.actions.contains("updateCheckDue"), "application activation must notify the shared update scheduler")
window.actions.removeAll()
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
require(window.actions.contains("updateCheckDue"), "wake must notify the shared update scheduler")
print("PASS: update scheduler activation and wake bridge")
window.hideOnClose = false
window.close()
require(!window.isVisible && delegate.receiver.disposed, "real close must clean up the receiver")
print("PASS: real close cleans up the receiver")

// Verify the titlebar route honors supported preferences without entering a Space.
final class TitlebarPolicyWindow: MainFlutterWindow {
  var zooms = 0, minimizes = 0
  override func performZoom(_ sender: Any?) { zooms += 1 }
  override func performMiniaturize(_ sender: Any?) { minimizes += 1 }
}
let titlebarWindow = TitlebarPolicyWindow(contentRect: NSRect(x: 200, y: 200, width: 440, height: 560),
  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
titlebarWindow.performTitlebarDoubleClick(action: "Maximize")
require(titlebarWindow.zooms == 1 && titlebarWindow.minimizes == 0, "title double-click zooms instead of entering fullscreen")
titlebarWindow.performTitlebarDoubleClick(action: "Minimize")
require(titlebarWindow.minimizes == 1, "title double-click honors minimize")
titlebarWindow.performTitlebarDoubleClick(action: "None")
require(titlebarWindow.zooms == 1 && titlebarWindow.minimizes == 1, "title double-click honors do nothing")
titlebarWindow.performTitlebarDoubleClick(action: "Fill")
require(titlebarWindow.zooms == 2, "Fill uses documented zoom fallback, not private API")
titlebarWindow.performTitlebarDoubleClick(action: nil)
require(titlebarWindow.zooms == 3, "missing titlebar preference defaults to zoom")
require(!titlebarWindow.styleMask.contains(.fullScreen), "title double-click must not enter fullscreen")
print("PASS: titlebar double-click policy")

func launchEvent(eventID: AEEventID = kAEOpenApplication, property: OSType? = nil) -> NSAppleEventDescriptor {
  let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: eventID,
    targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
  if let property = property { event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: keyAEPropData) }
  return event
}
require(DesktopLaunchSource(appleEvent: nil) == .manual, "missing launch event must default to manual")
require(DesktopLaunchSource(appleEvent: launchEvent()) == .manual, "ordinary app open must be manual")
require(DesktopLaunchSource(appleEvent: launchEvent(property: keyAELaunchedAsLogInItem)) == .loginItem,
  "the login-item Apple event must be recognized")
require(DesktopLaunchSource(appleEvent: launchEvent(property: kAEOpenApplication)) == .manual,
  "unrelated launch properties must not be treated as login")
require(DesktopLaunchSource(appleEvent: launchEvent(eventID: kAEReopenApplication, property: keyAELaunchedAsLogInItem)) == .manual,
  "reopen must remain manual even with a login property")
print("PASS: login Apple-event classification")

func startupWindow() -> RecordingWindow {
  let value = RecordingWindow(contentRect: NSRect(x: 200, y: 200, width: 440, height: 560),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  value.isReleasedWhenClosed = false
  value.installTestStartupTimeout()
  return value
}
let manualWindow = startupWindow()
require(!manualWindow.isVisible, "startup window must initially be hidden")
manualWindow.setDesktopLaunchSource(.manual)
manualWindow.finishDesktopStartup(trayAvailable: true)
require(manualWindow.isVisible, "manual cold launch must show the window even with a tray")
require(app.activationPolicy() == .regular, "manual cold launch must show the Dock icon")
require(!manualWindow.hasStartupTimeout, "completed startup must cancel its watchdog")
manualWindow.orderOut(nil)
manualWindow.finishDesktopStartup(trayAvailable: true)
require(!manualWindow.isVisible, "duplicate completion must not reopen a window the user hid")

let trayWindow = startupWindow()
trayWindow.setDesktopLaunchSource(.loginItem)
trayWindow.finishDesktopStartup(trayAvailable: true)
require(!trayWindow.isVisible, "login startup with a tray must not show the window")
require(app.activationPolicy() == .accessory, "login startup must remove the Dock icon")
trayWindow.markDesktopReady()
trayWindow.showApp()
require(trayWindow.isVisible, "reopen must show the existing login-started window")
require(app.activationPolicy() == .regular, "reopen must restore the Dock icon")
require(trayWindow.actions.contains("openApp"), "reopen must also reset the shared presentation policy")
trayWindow.orderOut(nil)
trayWindow.hideOnClose = true
trayWindow.finishDesktopStartup(trayAvailable: false)
require(trayWindow.isVisible && !trayWindow.hideOnClose, "later tray failure must show a closable fallback")
trayWindow.orderOut(nil)

for source in [DesktopLaunchSource.manual, .loginItem] {
  let pendingWindow = startupWindow()
  pendingWindow.finishDesktopStartup(trayAvailable: true)
  require(!pendingWindow.isVisible && !pendingWindow.hasFinishedStartup,
    "tray success before the launch callback must wait for the launch source")
  require(pendingWindow.hasStartupTimeout, "waiting for the launch source must retain the watchdog")
  pendingWindow.setDesktopLaunchSource(source)
  require(pendingWindow.isVisible == (source == .manual), "deferred startup must honor the captured launch source")
  require(pendingWindow.hasFinishedStartup && !pendingWindow.hasStartupTimeout,
    "the launch callback must complete pending tray startup and cancel its watchdog")
  pendingWindow.orderOut(nil)
}

let fallbackWindow = startupWindow()
fallbackWindow.setDesktopLaunchSource(.loginItem)
fallbackWindow.markDesktopReady()
fallbackWindow.finishDesktopStartup(trayAvailable: false)
require(fallbackWindow.isVisible, "unavailable tray must show fallback even for login startup")
require(app.activationPolicy() == .regular, "fallback must restore the Dock icon")
fallbackWindow.orderOut(nil)
fallbackWindow.showApp()
require(fallbackWindow.isVisible, "native reopen must work when Dart readiness was premature")
fallbackWindow.orderOut(nil)

for source in [DesktopLaunchSource.manual, .loginItem] {
  let reopenedWindow = startupWindow()
  reopenedWindow.showApp()
  reopenedWindow.finishDesktopStartup(trayAvailable: true)
  reopenedWindow.setDesktopLaunchSource(source)
  require(reopenedWindow.isVisible, "startup completion must preserve reopen before source or tray readiness")
  require(app.activationPolicy() == .regular, "pending reopen must keep its Dock icon")
  reopenedWindow.orderOut(nil)
}

// Invoke the actual scheduled native callback without waiting ten seconds or
// starting Dart. A missing launch callback must never suppress this fallback.
let watchdogWindow = startupWindow()
watchdogWindow.hideOnClose = true
watchdogWindow.markDesktopReady()
watchdogWindow.finishDesktopStartup(trayAvailable: true)
watchdogWindow.fireTestStartupTimeout()
require(watchdogWindow.isVisible && !watchdogWindow.hideOnClose,
  "watchdog must show a closable native window even before the launch source is known")
require(app.activationPolicy() == .regular, "watchdog fallback must restore the Dock icon")
watchdogWindow.setDesktopLaunchSource(.loginItem)
watchdogWindow.finishDesktopStartup(trayAvailable: true)
require(watchdogWindow.isVisible && app.activationPolicy() == .regular,
  "late login source or tray success must not undo watchdog recovery")
watchdogWindow.orderOut(nil)
print("PASS: manual/login startup, deferred launch source, native fallback and reopen")

// Exercise real AppKit animation cancellation without requiring a sender.
let resizeWindow = MainFlutterWindow(contentRect: NSRect(x: 200, y: 200, width: 440, height: 560),
  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
resizeWindow.makeKeyAndOrderFront(nil)
func runUntil(_ done: () -> Bool) {
  let deadline = Date().addingTimeInterval(2)
  while !done() && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  }
  require(done(), "native window animation must finish within its deadline")
}
let resizeTarget = NSRect(x: 180, y: 180, width: 800, height: 600)
var resizeResults: [Bool] = []
let started = Date()
resizeWindow.resizeWindow(to: resizeTarget, duration: 0.2) { resizeResults.append($0) }
require(Date().timeIntervalSince(started) < 0.1 && resizeResults.isEmpty,
  "animated resize must return before completion and leave the event loop running")
var resizeFrames = Set<String>()
runUntil {
  resizeFrames.insert(NSStringFromRect(resizeWindow.frame))
  return !resizeResults.isEmpty
}
print("Native resize: elapsed=\(Date().timeIntervalSince(started)) frames=\(resizeFrames.count)")
require(resizeFrames.count > 3, "animation must produce intermediate window frames")
require(resizeResults == [true] && resizeWindow.frame.equalTo(resizeTarget), "animation must reach its target exactly once")

let nextTarget = NSRect(x: 250, y: 200, width: 600, height: 700)
resizeWindow.resizeWindow(to: nextTarget, duration: 0.2) { resizeResults.append($0) }
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
let interruptedFrame = resizeWindow.frame
resizeWindow.cancelWindowResize()
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
require(resizeResults == [true, false] && resizeWindow.frame.equalTo(interruptedFrame),
  "cancellation must complete once without snapping to the stale target")
resizeWindow.resizeWindow(to: nextTarget, duration: 0) { resizeResults.append($0) }
require(resizeResults == [true, false, true] && resizeWindow.frame.equalTo(nextTarget),
  "reduced motion must apply the target without an animation")
resizeWindow.resizeWindow(to: resizeTarget, duration: 0.2) { resizeResults.append($0) }
resizeWindow.orderOut(nil)
require(resizeResults.last == false, "hiding must cancel an active resize")
resizeWindow.resizeWindow(to: nextTarget, duration: 0.2) { resizeResults.append($0) }
require(resizeResults.last == false, "hidden windows must defer resizing")
print("PASS: asynchronous resize, cancellation, reduced motion and hidden-window deferral")

resizeWindow.setFrame(NSRect(x: 200, y: 200, width: 440, height: 560), display: true)
resizeWindow.makeKeyAndOrderFront(nil)
var zoomResults: [Bool] = []
resizeWindow.resizeWindow(to: resizeTarget, duration: 0.2) { zoomResults.append($0) }
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
resizeWindow.performTitlebarDoubleClick(action: "Zoom")
let zoomedFrame = resizeWindow.frame
require(resizeWindow.isZoomed, "titlebar Zoom must maximize during an automatic resize")
runUntil { !zoomResults.isEmpty }
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
require(zoomResults == [false] && resizeWindow.isZoomed && resizeWindow.frame.equalTo(zoomedFrame),
  "Zoom must cancel the animation once and preserve the maximized window")
resizeWindow.orderOut(nil)
print("PASS: titlebar Zoom cancels resize and preserves maximized geometry")
