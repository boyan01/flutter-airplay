// SPDX-License-Identifier: GPL-3.0-or-later
import FlutterMacOS

final class ReceiverBridge: NSObject, FlutterStreamHandler {
    let host = ReceiverHost()
    private var video: FrameTexture?
    private var eventSink: FlutterEventSink?
    private var methods: FlutterMethodChannel?
    private var events: FlutterEventChannel?

    func install(on messenger: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {
        if video != nil { dispose() }
        let output = FrameTexture(registry: textures)
        video = output
        host.videoOutput = output
        output.onDimensions = { [weak self] width, height in
            self?.host.queue.async { [weak self] in self?.host.videoDimensions(width: width, height: height) }
        }
        methods = FlutterMethodChannel(name: "org.airplayreceiver/control", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "org.airplayreceiver/events", binaryMessenger: messenger)
        events?.setStreamHandler(self)
        host.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.eventSink?(event) }
        }
        methods?.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            self.video?.register()
            self.host.queue.async {
                do {
                    let args = call.arguments as? [String: Any] ?? [:]
                    var value: Any?
                    switch call.method {
                    case "snapshot": value = self.host.snapshot()
                    case "save":
                        try self.host.save(name: args["name"] as? String ?? "", path: args["path"] as? String ?? "")
                    case "check": value = try self.host.check(path: args["path"] as? String ?? "")
                    case "start":
                        try self.host.start(name: args["name"] as? String ?? "", path: args["path"] as? String ?? "")
                    case "stop": self.host.stop()
                    default:
                        DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
                        return
                    }
                    DispatchQueue.main.async { result(value) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "receiver_error", message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
    }

    func dispose() {
        methods?.setMethodCallHandler(nil)
        events?.setStreamHandler(nil)
        eventSink = nil
        host.shutdown()
        host.queue.sync {
            host.videoOutput = nil
            host.onEvent = nil
        }
        video?.dispose()
        video = nil
        methods = nil
        events = nil
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        video?.register()
        eventSink = events
        host.queue.async {
            let snapshot = self.host.snapshot()
            DispatchQueue.main.async { events(["type": "snapshot", "data": snapshot]) }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
