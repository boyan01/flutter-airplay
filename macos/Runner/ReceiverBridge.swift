// SPDX-License-Identifier: GPL-3.0-or-later
import FlutterMacOS
import Cocoa

final class ReceiverBridge: NSObject {
    let host = ReceiverHost()
    var onSnapshot: (([String: Any]) -> Void)?
    private var video: FrameTexture?
    private var methods: FlutterMethodChannel?

    func install(on messenger: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {
        if video != nil { dispose() }
        let output = FrameTexture(registry: textures)
        video = output
        host.videoOutput = output
        methods = FlutterMethodChannel(name: "org.airplayreceiver/platform", binaryMessenger: messenger)
        host.onEvent = { [weak self] event in
            guard event["type"] as? String == "snapshot", let snapshot = event["data"] as? [String: Any] else { return }
            DispatchQueue.main.async { self?.onSnapshot?(snapshot) }
        }
        methods?.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            guard call.method == "bootstrap" else { result(FlutterMethodNotImplemented); return }
            self.video?.register()
            self.host.queue.async {
                do {
                    let handle = try self.host.bootstrap()
                    let snapshot = self.host.snapshot()
                    DispatchQueue.main.async {
                        self.onSnapshot?(snapshot)
                        result(["handle": handle])
                    }
                } catch {
                    DispatchQueue.main.async { result(FlutterError(code: "receiver_error", message: error.localizedDescription, details: nil)) }
                }
            }
        }
    }

    func setDisplay(_ display: CGDirectDisplayID) {
        host.queue.async {
            self.host.displayID = display
        }
    }

    func nativeAction(_ action: @escaping (ReceiverHost) throws -> Void) {
        host.queue.async {
            do { try action(self.host) }
            catch { self.eventSinkOnMain(error.localizedDescription) }
        }
    }

    private func eventSinkOnMain(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert(); alert.messageText = message; alert.runModal()
        }
    }

    func dispose() {
        methods?.setMethodCallHandler(nil)
        host.shutdown()
        host.queue.sync {
            host.videoOutput = nil
            host.onEvent = nil
        }
        video?.dispose()
        video = nil
        methods = nil
    }

}
