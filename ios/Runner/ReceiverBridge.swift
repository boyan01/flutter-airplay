// SPDX-License-Identifier: GPL-3.0-or-later
import Flutter
import UIKit
import AVFAudio

final class ReceiverBridge: NSObject, NetServiceDelegate {
    let host = ReceiverHost()
    private var video: FrameTexture?
    private var methods: FlutterMethodChannel?
    private var services = [NetService]()
    private var serviceGeneration = 0
    private var observers = [NSObjectProtocol]()
    private var interrupted = false

    func install(registrar: FlutterPluginRegistrar) {
        let output = FrameTexture(registry: registrar.textures())
        video = output; output.register(); host.videoOutput = output
        host.foreground = UIApplication.shared.applicationState != .background
        methods = FlutterMethodChannel(name: "org.airplayreceiver/platform", binaryMessenger: registrar.messenger())
        host.onEvent = { event in
            guard event["type"] as? String == "snapshot", let snapshot = event["data"] as? [String: Any] else { return }
            DispatchQueue.main.async {
                let state = snapshot["status"] as? String ?? "stopped"
                UIApplication.shared.isIdleTimerDisabled = UIApplication.shared.applicationState != .background && ["starting", "waiting", "streaming"].contains(state)
            }
        }
        host.publish = { [weak self] name, identity, port, videoTXT, audioTXT, token in
            DispatchQueue.main.async { self?.publish(name, identity, port, videoTXT, audioTXT, token) }
        }
        host.unpublish = { [weak self] in DispatchQueue.main.async { self?.stopServices() } }
        methods?.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            guard call.method == "bootstrap" else { result(FlutterMethodNotImplemented); return }
            let foreground = UIApplication.shared.applicationState != .background
            let bounds = UIScreen.main.nativeBounds
            self.host.queue.async {
                self.host.foreground = foreground
                self.host.screenSize = (Int(bounds.width), Int(bounds.height))
                do {
                    let handle = try self.host.bootstrap()
                    DispatchQueue.main.async { result(["handle": handle]) }
                } catch {
                    DispatchQueue.main.async { result(FlutterError(code: "receiver_error", message: error.localizedDescription, details: nil)) }
                }
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        for notification in [AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] note in
                guard let self = self, !self.interrupted, UIApplication.shared.applicationState == .active else { return }
                if notification == AVAudioSession.routeChangeNotification {
                    let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                    guard reason != AVAudioSession.RouteChangeReason.categoryChange.rawValue else { return }
                }
                self.suspend(); self.resume()
            })
        }
    }

    func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began { interrupted = true; suspend() }
        else {
            interrupted = false
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if options.contains(.shouldResume) { resume() }
        }
    }

    private func publish(_ name: String, _ identity: Data, _ port: Int, _ videoTXT: Data, _ audioTXT: Data, _ token: Int) {
        // Publication follows successful audio activation. A newer interruption
        // synchronously invalidates this generation before services can appear.
        guard host.queue.sync(execute: { host.isCurrent(token) }) else { return }
        interrupted = false
        stopServices(); serviceGeneration = token
        let audioName = identity.map { String(format: "%02X", $0) }.joined() + "@" + name
        for (type, label, txt) in [("_airplay._tcp.", name, videoTXT), ("_raop._tcp.", audioName, audioTXT)] {
            let service = NetService(domain: "local.", type: type, name: label, port: Int32(port))
            service.delegate = self; service.setTXTRecord(txt); services.append(service); service.publish()
        }
    }
    private func stopServices() {
        for service in services { service.delegate = nil; service.stop() }
        services.removeAll()
    }
    func netServiceDidPublish(_ sender: NetService) {
        guard services.contains(where: { $0 === sender }) else { return }
        let token = serviceGeneration, type = sender.type
        host.queue.async { self.host.discoveryReady(type, token: token) }
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard services.contains(where: { $0 === sender }) else { return }
        let token = serviceGeneration, code = errorDict[NetService.errorCode]?.intValue ?? 0
        host.queue.async {
            self.host.discoveryFailed("Bonjour 发布失败 (\(code))。请允许设置中的本地网络访问，并检查同名设备。", token: token)
        }
    }
    // Called on the main thread before iOS can suspend the process.
    func suspend() {
        stopServices(); host.queue.sync { host.suspend() }
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func resume() {
        guard UIApplication.shared.applicationState != .background else { return }
        // Let the system decide whether audio can activate after suspension.
        host.queue.async { self.host.resume() }
    }
    func dispose() {
        stopServices(); host.shutdown()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(); video?.dispose(); video = nil
        methods?.setMethodCallHandler(nil)
    }
}
