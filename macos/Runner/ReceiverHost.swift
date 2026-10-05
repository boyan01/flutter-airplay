// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CoreVideo
import CoreGraphics

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
    let queue = DispatchQueue(label: "org.airplayreceiver.host")
    var videoOutput: ReceiverVideoOutput?
    var onEvent: (([String: Any]) -> Void)?
    var displayID = CGMainDisplayID()
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
            let deviceName = (Host.current().localizedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var clean = ""
            for scalar in deviceName.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
                let character = String(scalar)
                if clean.utf8.count + character.utf8.count > 50 { break }
                clean += character
            }
            clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(clean.isEmpty ? "Flutter AirPlay" : clean, forKey: "receiverName")
        }
    }

    private let videoQualities = ["auto", "720", "1080", "1440", "2160"]

    private func screenSize() -> (width: Int, height: Int) {
        // CGDisplayPixelsWide/High return logical dimensions in Retina modes.
        let selectedMode = CGDisplayIsActive(displayID) != 0 ? CGDisplayCopyDisplayMode(displayID) : nil
        let mode = selectedMode ?? CGDisplayCopyDisplayMode(CGMainDisplayID())
        return (mode?.pixelWidth ?? CGDisplayPixelsWide(CGMainDisplayID()),
                mode?.pixelHeight ?? CGDisplayPixelsHigh(CGMainDisplayID()))
    }

    func requestedVideoSize() -> (width: Int, height: Int) {
        let quality = defaults.string(forKey: "videoQuality") ?? "auto"
        let height = quality == "auto"
            ? min(2160, max(480, screenSize().height)) / 2 * 2
            : Int(quality) ?? 1080
        return ((height * 16 / 9 + 1) / 2 * 2, height)
    }

    func snapshot() -> [String: Any] {
        var data: [String: Any] = ["status": status, "message": message, "pid": player == nil ? 0 : getpid(),
            "clientName": clientName, "name": defaults.string(forKey: "receiverName") ?? "Flutter AirPlay",
            "path": "", "textureId": videoOutput?.textureIdentifier ?? -1,
            "videoWidth": videoWidth, "videoHeight": videoHeight, "logs": logs,
            "audioPlaying": audioPlaying, "videoPaused": videoPaused,
            "autoStart": defaults.object(forKey: "receiverAutoStart") as? Bool ?? true]
        for (key, fallback) in ["launchAtLogin": false, "keepInMenuBar": true, "showOnConnect": true,
                                "fullscreenOnConnect": false, "alwaysOnTop": false] {
            data[key] = defaults.object(forKey: key) as? Bool ?? fallback
        }
        data["videoQuality"] = defaults.string(forKey: "videoQuality") ?? "auto"
        data["videoQualities"] = videoQualities
        let screen = screenSize()
        data["screenWidth"] = screen.width
        data["screenHeight"] = screen.height
        data["capabilities"] = ["platform": "macos", "supportsExecutablePath": false,
            "supportsLaunchAtLogin": ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13]
        return data
    }

    func log(_ text: String) {
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
    func save(name: String, path: String, autoStart: Bool? = nil, videoQuality: String? = nil, options: [String: Bool] = [:]) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReceiverFailure(message: "macOS 使用内置 C++ 接收核心，无需指定路径。")
        }
        guard player == nil || clean == defaults.string(forKey: "receiverName") else {
            throw ReceiverFailure(message: "请先停止接收器再修改设备名。")
        }
        guard !clean.isEmpty, clean.utf8.count <= 50,
              !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ReceiverFailure(message: "设备名需要 1–50 个 UTF-8 字节，不能含控制字符。")
        }
        if let quality = videoQuality {
            guard videoQualities.contains(quality) else {
                throw ReceiverFailure(message: "Unknown video quality")
            }
            guard player == nil || quality == defaults.string(forKey: "videoQuality") ?? "auto" else {
                throw ReceiverFailure(message: "请先停止接收器再修改投屏清晰度。")
            }
            defaults.set(quality, forKey: "videoQuality")
        }
        defaults.set(clean, forKey: "receiverName")
        if let value = autoStart { defaults.set(value, forKey: "receiverAutoStart") }
        for (key, value) in options where ["launchAtLogin", "keepInMenuBar", "showOnConnect", "fullscreenOnConnect", "alwaysOnTop"].contains(key) {
            defaults.set(value, forKey: key)
        }
    }
    func check(path: String) throws {
        guard path.isEmpty else { throw ReceiverFailure(message: "macOS 使用内置接收核心。") }
        log("内置 C++ 接收与播放库已加载；VideoToolbox / CoreAudio 无外部运行依赖。")
    }
    func start(name: String, path: String) throws {
        guard player == nil else { return }
        try save(name: name, path: path)
        guard let video = videoOutput else { throw ReceiverFailure(message: "内嵌视频引擎未就绪。") }
        try video.begin()
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
            callbackContext = nil; video.end(); state("error", "无法初始化原生播放库。")
            throw ReceiverFailure(message: message)
        }
        player = native
        let size = requestedVideoSize()
        let screen = screenSize()
        log("Display mode pixels: \(screen.width)x\(screen.height)")
        guard airplay_player_set_video_size(native, Int32(size.width), Int32(size.height)) else {
            stop(); throw ReceiverFailure(message: "Invalid mirroring size")
        }
        log("Receiver request: quality=\(defaults.string(forKey: "videoQuality") ?? "auto"), \(size.width)x\(size.height), maxFPS=60; sender chooses actual codec/size/rate")
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
        state("waiting", "等待 iPhone · 请在控制中心选择此设备")
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
        case "error": videoOutput?.clear(); state("error", detail)
        default: break
        }
    }
    private func media() {
        onEvent?(["type": "media", "audioPlaying": audioPlaying, "videoPaused": videoPaused])
    }
    func stop() {
        guard let native = player else { return }
        generation += 1; state("stopping", "正在停止接收器…")
        airplay_player_destroy(native); player = nil; callbackContext = nil; videoOutput?.end()
        state("stopped", "接收器已停止")
    }
    func disconnect() {
        guard status == "streaming" else { return }
        let name = defaults.string(forKey: "receiverName") ?? "Flutter AirPlay"
        stop(); do { try start(name: name, path: "") } catch { state("error", error.localizedDescription) }
    }
    func shutdown() { queue.sync { stop() } }
}
