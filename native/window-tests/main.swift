// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS

// Only unrelated receiver/Flutter startup is stubbed. Window geometry and
// fullscreen requests execute the production MainFlutterWindow implementation.
final class TestReceiver {
  func dispose() {}
  func install(on: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {}
}
final class AppDelegate: NSObject, NSApplicationDelegate {
  let receiver = TestReceiver()
  func preference(_ key: String, default fallback: Bool) -> Bool { fallback }
  func hideWindow() {}
  func configureApplication() {}
}
func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {}

extension MainFlutterWindow {
  func setTestMode(_ dimensions: NSSize?) {
    playerDimensions = dimensions
    applyMode()
  }
  func completeTestTransition() {
    fullscreenTransition = false
    updateFullscreen()
  }
  func beginTestTransition() { fullscreenTransition = true }
}

func require(_ condition: Bool, _ message: String) {
  if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = MainFlutterWindow(
  contentRect: NSRect(x: 200, y: 200, width: 440, height: 560),
  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
  backing: .buffered, defer: false)
window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 560))
let portrait = NSSize(width: 1170, height: 2532)
let landscape = NSSize(width: 2532, height: 1170)
let cases: [(name: String, input: NSSize?, endsDuringFullscreen: Bool)] = [
  ("home", nil, false),
  ("portrait playback", portrait, false),
  ("landscape playback", landscape, false),
  ("home after playback", nil, false),
  ("playback ends during fullscreen", portrait, true),
  ("repeated home fullscreen", nil, false),
]
var index = 0
var observers: [NSObjectProtocol] = []
let center = NotificationCenter.default
for notification in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
  observers.append(center.addObserver(forName: notification, object: window, queue: .main) { _ in
    window.beginTestTransition()
  })
}
observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
  window.completeTestTransition()
  if cases[index].endsDuringFullscreen { window.setTestMode(nil) }
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { window.setFullscreen(false) }
})
observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
  window.completeTestTransition()
  let frame = window.frame
  require(frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
    && frame.width > 0 && frame.height > 0, "restored window frame must be finite and positive")
  require(window.styleMask.contains(.titled) && window.styleMask.contains(.fullSizeContentView),
    "fullscreen exit must preserve the standard content window")
  let size = window.contentRect(forFrameRect: frame).size
  let dimensions = cases[index].endsDuringFullscreen ? nil : cases[index].input
  if let dimensions = dimensions {
    require(abs(size.width / size.height - dimensions.width / dimensions.height) < 0.01,
      "playback window must restore the video aspect ratio")
  } else {
    require(abs(size.width - 440) < 1 && abs(size.height - 560) < 1,
      "home must restore its content size")
    require(window.resizeIncrements == NSSize(width: 1, height: 1),
      "home must clear playback aspect constraints")
  }
  print("PASS: \(cases[index].name)")
  index += 1
  if index == cases.count { exit(0) }
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    window.setTestMode(cases[index].input)
    window.setFullscreen(true)
  }
})
window.setTestMode(cases[0].input)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { window.setFullscreen(true) }
DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
  fputs("FAIL: fullscreen transition timed out\n", stderr)
  exit(2)
}
app.run()
