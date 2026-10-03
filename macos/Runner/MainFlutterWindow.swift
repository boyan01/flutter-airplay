import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func close() {
    (NSApp.delegate as? AppDelegate)?.receiver.dispose()
    super.close()
  }

  override func awakeFromNib() {
    let controller = FlutterViewController()
    contentViewController = controller
    setContentSize(NSSize(width: 1000, height: 740))
    minSize = NSSize(width: 760, height: 650)
    center()
    RegisterGeneratedPlugins(registry: controller)
    (NSApp.delegate as? AppDelegate)?.receiver.install(on: controller.engine.binaryMessenger, textures: controller.engine)
    super.awakeFromNib()
  }
}
