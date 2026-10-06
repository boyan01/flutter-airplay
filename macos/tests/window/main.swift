// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS

// Geometry and tray coverage lives in the real Flutter desktop integration test.
// This fixture checks the remaining host close and transition bridge.
final class TestReceiver {
  var disposed = false
  func dispose() { disposed = true }
  func install(on: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {}
  func setDisplay(_ display: CGDirectDisplayID) {}
}
final class AppDelegate: NSObject, NSApplicationDelegate {
  let receiver = TestReceiver()
  var keepRunningWithoutWindow = false
  func configureApplication() {}
}
func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {}
extension MainFlutterWindow {
  func installTestObservers() { installPresentationObservers() }
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
require(window.isVisible && !delegate.receiver.disposed, "close-to-tray must defer hiding and disconnect to Dart")
require(window.actions.contains("closeRequested"), "close must reach the shared policy")
print("PASS: close interception preserves the receiver")
NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
require(window.actions.contains("windowTransitionStarted"), "fullscreen transition must notify Dart before resizing")
print("PASS: fullscreen transition bridge")
window.hideOnClose = false
window.close()
require(!window.isVisible && delegate.receiver.disposed, "real close must clean up the receiver")
print("PASS: real close cleans up the receiver")
