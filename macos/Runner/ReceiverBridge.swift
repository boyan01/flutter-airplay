// SPDX-License-Identifier: GPL-3.0-or-later
import FlutterMacOS
import ServiceManagement
import Cocoa

final class ReceiverBridge: NSObject, FlutterStreamHandler {
    let host = ReceiverHost()
    var onSnapshot: (([String: Any]) -> Void)?
    private var video: FrameTexture?
    private var eventSink: FlutterEventSink?
    private var methods: FlutterMethodChannel?
    private var events: FlutterEventChannel?
    private var statsTimer: DispatchSourceTimer?

    func install(on messenger: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {
        if video != nil { dispose() }
        let output = FrameTexture(registry: textures)
        video = output
        host.videoOutput = output
        let timer = DispatchSource.makeTimerSource(queue: host.queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self, let text = self.video?.diagnostics() else { return }
            self.host.log(text)
        }
        statsTimer = timer; timer.resume()
        methods = FlutterMethodChannel(name: "org.airplayreceiver/control", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "org.airplayreceiver/events", binaryMessenger: messenger)
        events?.setStreamHandler(self)
        host.onEvent = { [weak self] event in
            guard let self = self else { return }
            let snapshot = self.host.snapshot()
            DispatchQueue.main.async { self.eventSink?(event); self.onSnapshot?(snapshot) }
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
                        if let requested = args["launchAtLogin"] as? Bool {
                            if #available(macOS 13.0, *) {
                                let enabled = SMAppService.mainApp.status == .enabled
                                if requested != enabled {
                                    if requested { try SMAppService.mainApp.register() }
                                    else { try SMAppService.mainApp.unregister() }
                                }
                            }
                        }
                        try self.host.save(name: args["name"] as? String ?? "", path: args["path"] as? String ?? "",
                                           autoStart: args["autoStart"] as? Bool,
                                           videoQuality: args["videoQuality"] as? String,
                                           options: args.compactMapValues { $0 as? Bool })
                        let snapshot = self.host.snapshot()
                        DispatchQueue.main.async { self.eventSink?(["type": "snapshot", "data": snapshot]); self.onSnapshot?(snapshot) }
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

    func setDisplay(_ display: CGDirectDisplayID) {
        host.queue.async {
            self.host.displayID = display
            let snapshot = self.host.snapshot()
            DispatchQueue.main.async {
                self.eventSink?(["type": "snapshot", "data": snapshot])
                self.onSnapshot?(snapshot)
            }
        }
    }

    func nativeAction(_ action: @escaping (ReceiverHost) throws -> Void) {
        host.queue.async {
            do { try action(self.host) }
            catch { self.eventSinkOnMain(error.localizedDescription) }
            let snapshot = self.host.snapshot()
            DispatchQueue.main.async {
                self.eventSink?(["type": "snapshot", "data": snapshot])
                self.onSnapshot?(snapshot)
            }
        }
    }

    private func eventSinkOnMain(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert(); alert.messageText = message; alert.runModal()
        }
    }

    func dispose() {
        statsTimer?.cancel(); statsTimer = nil
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
