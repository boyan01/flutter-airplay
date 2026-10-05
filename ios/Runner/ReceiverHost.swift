// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CoreVideo
import AVFAudio
import UIKit

struct ReceiverFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol ReceiverVideoOutput: AnyObject {
    var textureIdentifier: Int64 { get }
    func begin() throws
    func receive(_ frame: CVPixelBuffer)
    func clear()
    func end()
}

// The native library joins every callback before stop returns. Mutable UI state
// stays on queue; generation rejects events already queued by a stopped session.
final class ReceiverHost {
    private static let buildTime: String = {
        guard let url = Bundle.main.url(forResource: "build-time", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    let queue = DispatchQueue(label: "org.airplayreceiver.host")
    var videoOutput: ReceiverVideoOutput?
    var onEvent: (([String: Any]) -> Void)?
    private final class CallbackContext {
        weak var host: ReceiverHost?
        let video: ReceiverVideoOutput
        let generation: Int
        init(host: ReceiverHost, video: ReceiverVideoOutput, generation: Int) {
            self.host = host; self.video = video; self.generation = generation
        }
    }
    private var callbackContext: CallbackContext?
    private var player: OpaquePointer?
    var foreground = true
    private var resumeRequested = false
    var publish: ((String, Data, Int, Data, Data, Int) -> Void)?
    var unpublish: (() -> Void)?
    private var published = Set<String>()
    private var receivingName = ""
    private var activeSettings = [String: String]()
    private var clientName = ""
    private var videoWidth = 0, videoHeight = 0
    private var audioPlaying = false, videoPaused = false
    private var status = "stopped", message = "接收器未启动"
    private var generation = 0
    private var logID = 0
    private var logs = [[String: Any]]()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.string(forKey: "receiverName") == nil {
            defaults.set(defaultName(), forKey: "receiverName")
        }
    }

    private func defaultName() -> String {
        let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var clean = ""
        for scalar in deviceName.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            let character = String(scalar)
            if clean.utf8.count + character.utf8.count > 50 { break }
            clean += character
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Flutter AirPlay" : clean
    }

    func applySettings() throws -> Bool {
        guard status == "waiting", let native = player,
              airplay_player_prepare_restart(native) else { return false }
        let name = defaults.string(forKey: "receiverName") ?? defaultName()
        stop()
        do {
            try start(name: name, path: "", foreground: foreground)
            return true
        } catch {
            state("error", error.localizedDescription)
            throw error
        }
    }

    func snapshot() -> [String: Any] {
        var data: [String: Any] = ["status": status, "message": message, "pid": player == nil ? 0 : getpid(),
            "clientName": clientName, "name": defaults.string(forKey: "receiverName") ?? "Flutter AirPlay",
            "path": "", "textureId": videoOutput?.textureIdentifier ?? -1,
            "videoWidth": videoWidth, "videoHeight": videoHeight, "logs": logs,
            "audioPlaying": audioPlaying, "videoPaused": videoPaused,
            "autoStart": defaults.object(forKey: "receiverAutoStart") == nil ? true : defaults.bool(forKey: "receiverAutoStart")]
        data["defaultName"] = defaultName()
        data["activeSettings"] = activeSettings
        data["receivingName"] = receivingName
        data["buildTime"] = Self.buildTime
        data["capabilities"] = ["platform": "ios", "supportsExecutablePath": false,
            "supportsLaunchAtLogin": false, "foregroundOnly": true]
        return data
    }

    private func log(_ text: String) {
        logID += 1
        let item: [String: Any] = ["id": logID, "time": ISO8601DateFormatter().string(from: Date()), "text": String(text.prefix(4096))]
        logs.append(item)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        onEvent?(["type": "log", "entry": item])
    }
    private func state(_ next: String, _ detail: String) {
        status = next; message = detail
        if ["waiting", "stopping", "stopped", "error"].contains(next) {
            clientName = ""; videoWidth = 0; videoHeight = 0; audioPlaying = false; videoPaused = false
        }
        onEvent?(["type": "state", "status": next, "message": detail, "pid": player == nil ? 0 : getpid()])
    }
    func save(name: String, path: String, autoStart: Bool? = nil, options: [String: Bool] = [:]) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReceiverFailure(message: "iPad 使用内置接收核心，无需指定路径。")
        }
        guard !clean.isEmpty, clean.utf8.count <= 50,
              !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ReceiverFailure(message: "设备名需要 1–50 个 UTF-8 字节，不能含控制字符。")
        }
        defaults.set(clean, forKey: "receiverName")
        if let value = autoStart { defaults.set(value, forKey: "receiverAutoStart") }

    }
    func check(path: String) throws {
        guard path.isEmpty else { throw ReceiverFailure(message: "iPad 使用内置接收核心。") }
        log("内置接收库已加载；VideoToolbox / AudioConverter / RemoteIO。请保持应用在前台。")
    }
    func start(name: String, path: String, foreground: Bool) throws {
        // Engine installation can precede scene activation. Use the newer
        // application state carried by the request from the main thread.
        self.foreground = foreground
        guard player == nil else { return }
        guard self.foreground else { throw ReceiverFailure(message: "请在应用前台启动接收器。") }
        try save(name: name, path: path)
        guard let video = videoOutput else { throw ReceiverFailure(message: "内嵌视频引擎未就绪。") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setPreferredSampleRate(44100)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        do { try video.begin() }
        catch { try? session.setActive(false, options: .notifyOthersOnDeactivation); throw error }
        generation += 1
        state("starting", "正在注册 Bonjour 接收服务…")
        let context = CallbackContext(host: self, video: video, generation: generation)
        callbackContext = context
        var callbacks = AirplayCallbacks()
        callbacks.context = Unmanaged.passUnretained(context).toOpaque()
        callbacks.event = { context, type, detail, width, height in
            guard let context = context, let type = type else { return }
            let current = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            guard let host = current.host else { return }
            let token = current.generation
            let event = String(cString: type), text = detail.map { String(cString: $0) } ?? ""
            host.queue.async { if token == host.generation { host.receive(event, text, Int(width), Int(height)) } }
        }
        callbacks.log = { context, _, text in
            guard let context = context, let text = text else { return }
            let current = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            guard let host = current.host else { return }
            let token = current.generation, message = String(cString: text)
            host.queue.async { if token == host.generation { host.log(message) } }
        }
        callbacks.frame = { context, frame in
            guard let context = context, let frame = frame else { return }
            let current = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            let pixel = Unmanaged<CVPixelBuffer>.fromOpaque(frame).takeUnretainedValue()
            guard let host = current.host else { return }
            let token = current.generation
            host.queue.async { if token == host.generation { current.video.receive(pixel) } }
        }
        guard let native = airplay_player_create(callbacks, nil, nil, nil) else {
            callbackContext = nil; video.end(); try? session.setActive(false); state("error", "无法初始化原生播放库。")
            throw ReceiverFailure(message: message)
        }
        receivingName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSettings = ["name": receivingName, "path": ""]
        player = native
        var identity = defaults.data(forKey: "receiverIdentity")
        if identity?.count != 6 {
            var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
            bytes[0] = (bytes[0] | 2) & 254; identity = Data(bytes)
            defaults.set(identity, forKey: "receiverIdentity")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "tech.soit.flutterairplay")
        do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
        catch { stop(); throw error }
        var error = [CChar](repeating: 0, count: 512)
        let started = identity!.withUnsafeBytes { bytes in
            airplay_player_start(native, name, bytes.bindMemory(to: UInt8.self).baseAddress!,
                                 support.appendingPathComponent("airplay-pairing.pem").path, &error, error.count)
        }
        if !started {
            let detail = String(cString: error)
            stop(); state("error", detail); throw ReceiverFailure(message: detail)
        }
        published.removeAll()
        func txt(_ audio: Bool) -> Data {
            let size = airplay_player_txt(native, audio, nil, 0)
            var bytes = [UInt8](repeating: 0, count: size)
            _ = airplay_player_txt(native, audio, &bytes, size)
            return Data(bytes)
        }
        publish?(name, identity!, Int(airplay_player_port(native)), txt(false), txt(true), generation)
    }
    private func receive(_ event: String, _ detail: String, _ width: Int, _ height: Int) {
        guard player != nil else { return }
        switch event {
        case "client":
            clientName = detail; onEvent?(["type": "client", "name": detail])
            state("streaming", "已建立连接，等待第一帧画面")
        case "connecting": if videoWidth == 0 { state("streaming", "已建立连接，等待第一帧画面") }
        case "playing":
            if videoPaused { videoPaused = false; media() }
            if videoWidth != width || videoHeight != height {
                videoWidth = width; videoHeight = height
                onEvent?(["type": "video", "textureId": videoOutput?.textureIdentifier ?? -1,
                          "videoWidth": width, "videoHeight": height])
            }
            if message != "正在播放屏幕镜像" { state("streaming", "正在播放屏幕镜像") }
        case "waiting": videoOutput?.clear(); state("waiting", "连接已结束 · 等待下一次投屏")
        case "paused", "reset":
            videoPaused = event == "paused"
            if event == "reset" { audioPlaying = false }
            videoOutput?.clear(); videoWidth = 0; videoHeight = 0
            onEvent?(["type": "video", "textureId": videoOutput?.textureIdentifier ?? -1, "videoWidth": 0, "videoHeight": 0])
            media()
            if event == "paused" { state("streaming", "画面已暂停") }
        case "audio", "audio_stopped":
            audioPlaying = event == "audio"; media()
            if audioPlaying && videoWidth == 0 { state("streaming", "音频播放中") }
        case "error": stop(); state("error", detail)
        default: break
        }
    }
    private func media() {
        onEvent?(["type": "media", "audioPlaying": audioPlaying, "videoPaused": videoPaused])
    }
    func stop() {
        guard let native = player else { return }
        generation += 1; state("stopping", "正在停止接收器…")
        unpublish?()
        airplay_player_destroy(native); player = nil; callbackContext = nil; videoOutput?.end()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state("stopped", "接收器已停止")
    }
    func disconnect() {
        guard status == "streaming" else { return }
        let name = defaults.string(forKey: "receiverName") ?? "Flutter AirPlay"
        stop(); do { try start(name: name, path: "", foreground: foreground) } catch { state("error", error.localizedDescription) }
    }
    func discoveryReady(_ type: String, token: Int) {
        guard token == generation, player != nil else { return }
        published.insert(type)
        if published.count == 2, status == "starting" {
            state("waiting", "等待 iPhone · 请保持应用在前台")
        }
    }
    func isCurrent(_ token: Int) -> Bool { token == generation && player != nil && foreground }
    func discoveryFailed(_ detail: String, token: Int) {
        guard token == generation, player != nil else { return }
        stop(); state("error", detail)
    }
    func suspend() {
        resumeRequested = resumeRequested || player != nil
        foreground = false
        stop()
    }
    func resume() {
        foreground = true
        guard resumeRequested else { return }
        do {
            try start(name: defaults.string(forKey: "receiverName") ?? "Flutter AirPlay", path: "", foreground: foreground)
            resumeRequested = false
        }
        catch { state("error", error.localizedDescription) }
    }
    func userStop() { resumeRequested = false; stop() }
    func shutdown() { queue.sync { stop() } }
}
