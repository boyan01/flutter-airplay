// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CoreVideo
#if os(macOS)
import CoreGraphics
#else
import UIKit
import AVFAudio
#endif

struct ReceiverFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
protocol ReceiverVideoOutput: AnyObject {
    var textureIdentifier: Int64 { get }
    func begin() throws
    func receive(_ frame: CVPixelBuffer, deadline: Int64)
    func clear()
    func end()
    func diagnostics() -> String?
}
extension ReceiverVideoOutput {
    func diagnostics() -> String? { nil }
}

// Apple system/texture adapter. The shared C++ receiver owns runtime settings, playback
// lifecycle and state. This queue only dispatches native menu/system requests.
final class ReceiverHost {
    let queue = DispatchQueue(label: "org.airplayreceiver.adapter")
    var videoOutput: ReceiverVideoOutput?
    var onEvent: (([String: Any]) -> Void)?
    var publish: ((String, Data, Int, Data, Data, Int) -> Void)?
    var unpublish: (() -> Void)?
    private let discoveryLock = NSLock()
    private var published = Set<String>()
    private let defaults: UserDefaults
    private let support: URL
    private var handle: UInt64 = 0
    func reportOutputError(_ message: String) {
        airplay_receiver_output_error(handle, message)
    }
    private var closed = false
    private var bootstrapError: String?
    var foreground = true { didSet { if handle != 0 { updateMetadata() } } }
#if os(macOS)
    var displayID = CGMainDisplayID() { didSet { if handle != 0 { updateMetadata() } } }
#endif
    var screenSize: (width: Int, height: Int) { didSet { if handle != 0 { updateMetadata() } } }
    private static let buildTime: String = {
        guard let url = Bundle.main.url(forResource: "build-time", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    init(defaults: UserDefaults = .standard, screenSize: (width: Int, height: Int)? = nil,
         supportDirectory: URL? = nil) {
        self.defaults = defaults
        support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "tech.soit.flutterairplay")
#if os(macOS)
        self.screenSize = screenSize ?? (1920, 1080)
#else
        self.screenSize = screenSize ?? (Int(UIScreen.main.nativeBounds.width), Int(UIScreen.main.nativeBounds.height))
#endif
    }
    deinit { if handle != 0 { airplay_receiver_destroy(handle) } }
    private func defaultName() -> String {
#if os(macOS)
        let device = Host.current().localizedName ?? ""
#else
        let device = UIDevice.current.name
#endif
        return device
    }

    private func metadata() -> [String: Any] {
        var size = screenSize
#if os(macOS)
        let mode = CGDisplayIsActive(displayID) != 0 ? CGDisplayCopyDisplayMode(displayID) : nil
        let selected = mode ?? CGDisplayCopyDisplayMode(CGMainDisplayID())
        size = (selected?.pixelWidth ?? CGDisplayPixelsWide(CGMainDisplayID()), selected?.pixelHeight ?? CGDisplayPixelsHigh(CGMainDisplayID()))
        let capabilities: [String: Any] = ["platform": "macos", "nativeVideoSurface": true, "supportsExecutablePath": false,
            "supportsLaunchAtLogin": ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13]
#else
        let capabilities: [String: Any] = ["platform": "ios", "supportsExecutablePath": false, "supportsLaunchAtLogin": false, "foregroundOnly": true]
#endif
        return ["defaultName": defaultName(), "buildTime": Self.buildTime, "capabilities": capabilities,
            "screenWidth": size.width, "screenHeight": size.height, "foreground": foreground]
    }
    private func encode(_ value: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    private static func decode(_ text: UnsafePointer<CChar>) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) as? [String: Any] ?? [:]
    }
    private static func writeError(_ message: String, _ output: UnsafeMutablePointer<CChar>?, _ capacity: Int) {
        guard let output = output, capacity > 0 else { return }
        let bytes = message.utf8CString
        let count = min(bytes.count - 1, capacity - 1)
        bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: count) }
        output[count] = 0
    }
    private func updateMetadata() {
        if let bytes = try? encode(metadata()) { airplay_receiver_update(handle, bytes) }
    }
    func bootstrap() throws -> UInt64 {
        guard !closed else { throw ReceiverFailure(message: "Native receiver adapter has closed") }
        if handle != 0 { return handle }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var identity = defaults.data(forKey: "receiverIdentity")
        if identity?.count != 6 {
            var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
            bytes[0] = (bytes[0] | 2) & 254; identity = Data(bytes)
            defaults.set(identity, forKey: "receiverIdentity")
        }
        var hooks = AirplayReceiverHost()
        hooks.context = Unmanaged.passUnretained(self).toOpaque()
        hooks.create_player = { context, callbacks, _, _, _, output, capacity in
            let host = Unmanaged<ReceiverHost>.fromOpaque(context!).takeUnretainedValue()
            do {
                guard let output = host.videoOutput else { throw ReceiverFailure(message: "内嵌视频引擎未就绪。") }
#if !os(macOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setPreferredSampleRate(44100)
                try session.setPreferredIOBufferDuration(0.01)
                try session.setActive(true)
#endif
                try output.begin()
                return airplay_player_create(callbacks, nil, nil, nil)
            } catch { ReceiverHost.writeError(error.localizedDescription, output, capacity); return nil }
        }
        hooks.end_video = { context, _ in
            let host = Unmanaged<ReceiverHost>.fromOpaque(context!).takeUnretainedValue()
            host.videoOutput?.end()
#if !os(macOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
        }
        hooks.clear_video = { context in Unmanaged<ReceiverHost>.fromOpaque(context!).takeUnretainedValue().videoOutput?.clear() }
        hooks.texture_id = { context in Unmanaged<ReceiverHost>.fromOpaque(context!).takeUnretainedValue().videoOutput?.textureIdentifier ?? -1 }
        hooks.frame = { context, frame, deadline in
            guard let frame = frame else { return }
            // The output retains the borrowed buffer before this callback returns.
            Unmanaged<ReceiverHost>.fromOpaque(context!).takeUnretainedValue().videoOutput?.receive(Unmanaged<CVPixelBuffer>.fromOpaque(frame).takeUnretainedValue(), deadline: deadline)
        }
        hooks.diagnostics = { context, output, capacity in
            let host = Unmanaged<ReceiverHost>.fromOpaque(context!).takeUnretainedValue()
            if let report = host.videoOutput?.diagnostics() { ReceiverHost.writeError(report, output, capacity) }
        }
        hooks.event = { context, json in
            guard let json = json else { return }
            Unmanaged<ReceiverHost>.fromOpaque(context!).takeUnretainedValue().onEvent?(ReceiverHost.decode(json))
        }
#if !os(macOS)
        hooks.publish = { context, generation, name, identity, port, video, videoSize, audio, audioSize, _, _ in
            let host = Unmanaged<ReceiverHost>.fromOpaque(context!).takeUnretainedValue()
            host.discoveryLock.lock(); host.published.removeAll(); host.discoveryLock.unlock()
            host.publish?(String(cString: name!), Data(bytes: identity!, count: 6), Int(port), Data(bytes: video!, count: videoSize), Data(bytes: audio!, count: audioSize), Int(generation))
            return 0
        }
        hooks.unpublish = { context in Unmanaged<ReceiverHost>.fromOpaque(context!).takeUnretainedValue().unpublish?() }
#endif
        var error = [CChar](repeating: 0, count: 512)
        let meta = try encode(metadata())
        handle = identity!.withUnsafeBytes { bytes in
            airplay_receiver_create(hooks, meta, support.appendingPathComponent("airplay-pairing.pem").path,
                bytes.bindMemory(to: UInt8.self).baseAddress!, &error, error.count)
        }
        guard handle != 0 else { bootstrapError = String(cString: error); throw ReceiverFailure(message: bootstrapError!) }
        return handle
    }
    private func perform(_ action: (UInt64, UnsafeMutablePointer<CChar>, Int) -> Bool) throws {
        let receiver = try bootstrap()
        var error = [CChar](repeating: 0, count: 512)
        let success = error.withUnsafeMutableBufferPointer { action(receiver, $0.baseAddress!, $0.count) }
        if !success { throw ReceiverFailure(message: String(cString: error)) }
    }
    private static func string(_ value: UnsafePointer<CChar>?) -> String { value.map { String(cString: $0) } ?? "" }
    private static let qualities = ["auto", "720", "1080", "1440", "2160"]
    private static let audioOutputs = ["auto", "aaudio", "audiotrack"]
    private static func settings(_ value: AirplayReceiverSettings) -> [String: Any] {
        var result: [String: Any] = [:]
        if value.fields & UInt32(AIRPLAY_SETTING_NAME.rawValue) != 0 { result["name"] = string(value.name) }
        if value.fields & UInt32(AIRPLAY_SETTING_PATH.rawValue) != 0 { result["path"] = string(value.path) }
        if value.fields & UInt32(AIRPLAY_SETTING_VIDEO_QUALITY.rawValue) != 0 { result["videoQuality"] = qualities[Int(value.video_quality)] }
        if value.fields & UInt32(AIRPLAY_SETTING_AUDIO_OUTPUT.rawValue) != 0 { result["audioOutput"] = audioOutputs[Int(value.audio_output)] }
        if value.fields & UInt32(AIRPLAY_SETTING_AUTO_START.rawValue) != 0 { result["autoStart"] = value.auto_start }
        if value.fields & UInt32(AIRPLAY_SETTING_FAST_PAIRING.rawValue) != 0 { result["fastPairing"] = value.fast_pairing }
        if value.fields & UInt32(AIRPLAY_SETTING_LAUNCH_AT_LOGIN.rawValue) != 0 { result["launchAtLogin"] = value.launch_at_login }
        if value.fields & UInt32(AIRPLAY_SETTING_KEEP_IN_MENU_BAR.rawValue) != 0 { result["keepInMenuBar"] = value.keep_in_menu_bar }
        if value.fields & UInt32(AIRPLAY_SETTING_SHOW_ON_CONNECT.rawValue) != 0 { result["showOnConnect"] = value.show_on_connect }
        if value.fields & UInt32(AIRPLAY_SETTING_FULLSCREEN_ON_CONNECT.rawValue) != 0 { result["fullscreenOnConnect"] = value.fullscreen_on_connect }
        if value.fields & UInt32(AIRPLAY_SETTING_ALWAYS_ON_TOP.rawValue) != 0 { result["alwaysOnTop"] = value.always_on_top }
        if value.fields & UInt32(AIRPLAY_SETTING_PLAYBACK_BUFFER.rawValue) != 0 { result["playbackBufferMs"] = value.playback_buffer_ms }
        return result
    }
    private static func snapshot(_ value: AirplayReceiverSnapshot) -> [String: Any] {
        var result = settings(value.settings)
        result["activeSettings"] = settings(value.active_settings)
        result["status"] = ["stopped", "starting", "waiting", "streaming", "stopping", "error"][Int(value.status)]
        result["message"] = string(value.message)
        result["clientName"] = string(value.client_name)
        result["receivingName"] = string(value.receiving_name)
        result["defaultName"] = string(value.default_name)
        result["buildTime"] = string(value.build_time)
        result["capabilities"] = ["platform": string(value.platform),
            "supportsExecutablePath": value.supports_executable_path,
            "supportsLaunchAtLogin": value.supports_launch_at_login,
            "supportsAacEld": value.supports_aac_eld,
            "isTelevision": value.is_television,
            "nativeVideoSurface": value.native_video_surface,
            "foregroundOnly": value.foreground_only]
        result["videoQualities"] = qualities.enumerated().filter { value.video_quality_mask & (1 << UInt32($0.offset)) != 0 }.map { $0.element }
        result["screenWidth"] = Int(value.screen_width)
        result["screenHeight"] = Int(value.screen_height)
        result["autoVideoHeight"] = Int(value.auto_video_height)
        result["videoWidth"] = Int(value.video_width)
        result["videoHeight"] = Int(value.video_height)
        result["generation"] = Int(value.generation)
        result["pid"] = Int(value.pid)
        result["textureId"] = value.texture_id
        result["audioPlaying"] = value.audio_playing; result["videoPaused"] = value.video_paused
        result["logs"] = (0..<Int(value.log_count)).map { index -> [String: Any] in
            let entry = value.logs!.advanced(by: index).pointee
            return ["id": Int(entry.id), "time": string(entry.time), "text": string(entry.text)]
        }
        return result
    }
    func snapshot() -> [String: Any] {
        do {
            var error = [CChar](repeating: 0, count: 512)
            guard let value = airplay_receiver_snapshot(try bootstrap(), &error, error.count) else { throw ReceiverFailure(message: String(cString: error)) }
            defer { airplay_receiver_free_snapshot(value) }
            return Self.snapshot(value.pointee)
        } catch {
            return metadata().merging(["name": defaultName(), "path": "", "status": "error", "message": error.localizedDescription, "pid": 0], uniquingKeysWith: { _, value in value })
        }
    }
    func requestedVideoSize() -> (width: Int, height: Int) {
        var size = AirplayVideoSize()
        _ = try? perform { airplay_receiver_requested_video_size($0, &size, $1, $2) }
        return (Int(size.width), Int(size.height))
    }
    private static func options(_ values: [String: Bool], into result: inout AirplayReceiverSettings) {
        if let value = values["autoStart"] { result.fields |= UInt32(AIRPLAY_SETTING_AUTO_START.rawValue); result.auto_start = value }
        if let value = values["fastPairing"] { result.fields |= UInt32(AIRPLAY_SETTING_FAST_PAIRING.rawValue); result.fast_pairing = value }
        if let value = values["launchAtLogin"] { result.fields |= UInt32(AIRPLAY_SETTING_LAUNCH_AT_LOGIN.rawValue); result.launch_at_login = value }
        if let value = values["keepInMenuBar"] { result.fields |= UInt32(AIRPLAY_SETTING_KEEP_IN_MENU_BAR.rawValue); result.keep_in_menu_bar = value }
        if let value = values["showOnConnect"] { result.fields |= UInt32(AIRPLAY_SETTING_SHOW_ON_CONNECT.rawValue); result.show_on_connect = value }
        if let value = values["fullscreenOnConnect"] { result.fields |= UInt32(AIRPLAY_SETTING_FULLSCREEN_ON_CONNECT.rawValue); result.fullscreen_on_connect = value }
        if let value = values["alwaysOnTop"] { result.fields |= UInt32(AIRPLAY_SETTING_ALWAYS_ON_TOP.rawValue); result.always_on_top = value }
    }
    func save(name: String, path: String, autoStart: Bool? = nil, videoQuality: String? = nil, fastPairing: Bool? = nil, playbackBufferMs: Int32? = nil, options: [String: Bool] = [:]) throws {
        var settings = AirplayReceiverSettings()
        var flags = options; flags["autoStart"] = autoStart; flags["fastPairing"] = fastPairing
        Self.options(flags, into: &settings)
        if let buffer = playbackBufferMs {
            settings.fields |= UInt32(AIRPLAY_SETTING_PLAYBACK_BUFFER.rawValue); settings.playback_buffer_ms = buffer
        }
        if let quality = videoQuality {
            guard let index = Self.qualities.firstIndex(of: quality) else { throw ReceiverFailure(message: "Unknown video quality") }
            settings.fields |= UInt32(AIRPLAY_SETTING_VIDEO_QUALITY.rawValue); settings.video_quality = Int32(index)
        }
        settings.fields |= UInt32(AIRPLAY_SETTING_NAME.rawValue | AIRPLAY_SETTING_PATH.rawValue)
        try name.utf8CString.withUnsafeBufferPointer { bytes in
            try path.utf8CString.withUnsafeBufferPointer { pathBytes in
                settings.name = bytes.baseAddress; settings.name_size = bytes.count - 1
                settings.path = pathBytes.baseAddress; settings.path_size = pathBytes.count - 1
                try perform { airplay_receiver_save($0, &settings, $1, $2) }
            }
        }
    }
    func requestSettings(_ settings: [String: Bool]) throws {
        var value = AirplayReceiverSettings(); Self.options(settings, into: &value)
        airplay_receiver_request_settings(try bootstrap(), &value)
    }
    func start(name: String, path: String, foreground: Bool = true) throws {
        self.foreground = foreground
#if !os(macOS)
        guard foreground else { throw ReceiverFailure(message: "请在应用前台启动接收器。") }
#endif
        try save(name: name, path: path)
        try perform { airplay_receiver_start($0, UInt64.max, $1, $2) }
    }
    func applySettings() throws -> Bool {
        var result = false; try perform { airplay_receiver_apply_settings($0, &result, $1, $2) }; return result
    }
    func check(path: String) throws {
        try path.utf8CString.withUnsafeBufferPointer { bytes in
            try perform { airplay_receiver_check($0, bytes.baseAddress, bytes.count - 1, $1, $2) }
        }
    }
    func stop() { _ = try? perform { airplay_receiver_stop($0, $1, $2) } }
    func disconnect() { _ = try? perform { airplay_receiver_disconnect($0, $1, $2) } }
    func log(_ message: String) { if let handle = try? bootstrap() { airplay_receiver_log(handle, message) } }
    func userStop() { stop() }
    func suspend() { foreground = false; _ = try? perform { airplay_receiver_suspend($0, $1, $2) } }
    func resume() { foreground = true; _ = try? perform { airplay_receiver_resume($0, $1, $2) } }
    func isCurrent(_ token: Int) -> Bool {
        let value = snapshot()
        return (value["generation"] as? NSNumber)?.intValue == token && ((value["pid"] as? NSNumber)?.intValue ?? 0) > 0 && foreground
    }
    func discoveryReady(_ type: String, token: Int) {
        guard isCurrent(token) else { return }
        discoveryLock.lock(); published.insert(type); let ready = published.count == 2; discoveryLock.unlock()
        if ready { airplay_receiver_discovery(handle, UInt64(token), true, nil, nil) }
    }
    func discoveryFailed(_ detail: String, token: Int) { airplay_receiver_discovery(handle, UInt64(token), false, detail, nil) }
    func shutdown() { if handle != 0 { airplay_receiver_destroy(handle); handle = 0 }; closed = true }
}
