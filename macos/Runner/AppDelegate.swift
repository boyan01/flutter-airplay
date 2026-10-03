import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  let receiver = ReceiverBridge()

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    receiver.dispose()
    super.applicationWillTerminate(notification)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
