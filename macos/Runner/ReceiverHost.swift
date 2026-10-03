// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct ReceiverFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol ReceiverVideoOutput: AnyObject {
    var textureIdentifier: Int64 { get }
    func begin() throws -> String
    func clear()
    func end()
}

// All mutable receiver state is confined to queue. The Flutter bridge owns no process.
final class ReceiverHost {
    let queue = DispatchQueue(label: "org.airplayreceiver.process")
    var videoOutput: ReceiverVideoOutput?
    private var clientName = ""
    private var videoWidth = 0
    private var videoHeight = 0
    var onEvent: (([String: Any]) -> Void)?
    private var process: Process?
    private var output: Pipe?
    private var pending = Data()
    private var status = "stopped"
    private var message = "接收器未启动"
    private var generation = 0
    private var stopping = false
    private var logID = 0
    private var logs = [[String: Any]]()
    private let defaults: UserDefaults
    private let bundledPath: String
    private let inspectorOverride: String?
    private var pluginWorkspace: URL?

    init(bundledPath: String? = nil, inspectorPath: String? = nil,
         defaults: UserDefaults = .standard) {
        self.bundledPath = bundledPath ??
            (Bundle.main.resourceURL?.appendingPathComponent("receiver/uxplay").path ?? "")
        self.inspectorOverride = inspectorPath
        self.defaults = defaults
    }

    func snapshot() -> [String: Any] {
        var data: [String: Any] = ["status": status, "message": message, "pid": process?.processIdentifier ?? 0,
         "clientName": clientName, "name": defaults.string(forKey: "receiverName") ?? "Flutter AirPlay",
         "path": defaults.string(forKey: "receiverPath") ?? "",
         "textureId": videoOutput?.textureIdentifier ?? -1,
         "videoWidth": videoWidth, "videoHeight": videoHeight,
         "logs": logs, "autoStart": defaults.object(forKey: "receiverAutoStart") as? Bool ?? true]
        for (key, value) in ["launchAtLogin": false, "keepInMenuBar": true, "showOnConnect": true,
                              "fullscreenOnConnect": false, "alwaysOnTop": false] {
            data[key] = defaults.object(forKey: key) as? Bool ?? value
        }
        data["capabilities"] = ["platform": "macos", "supportsExecutablePath": true,
                               "supportsLaunchAtLogin": ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13]
        return data
    }

    private func log(_ text: String) {
        logID += 1
        let item: [String: Any] = ["id": logID, "time": ISO8601DateFormatter().string(from: Date()),
                                   "text": String(text.prefix(4096))]
        logs.append(item)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        onEvent?(["type": "log", "entry": item])
    }

    private func state(_ next: String, _ detail: String) {
        status = next
        if ["waiting", "stopping", "stopped", "error"].contains(next) {
            clientName = ""; videoWidth = 0; videoHeight = 0
        }
        message = detail
        onEvent?(["type": "state", "status": status, "message": message,
                  "pid": process?.processIdentifier ?? 0])
    }

    func save(name: String, path: String, autoStart: Bool? = nil, options: [String: Bool] = [:]) throws {
        let unchanged = name == defaults.string(forKey: "receiverName") &&
            path == (defaults.string(forKey: "receiverPath") ?? "")
        guard process == nil || unchanged else { throw ReceiverFailure(message: "请先停止接收器再修改设置。") }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= 50,
              !cleanName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ReceiverFailure(message: "设备名不能为空，最多 50 个 UTF-8 字节，不能含换行。")
        }
        if let autoStart = autoStart { defaults.set(autoStart, forKey: "receiverAutoStart") }
        for (key, value) in options where ["launchAtLogin", "keepInMenuBar", "showOnConnect", "fullscreenOnConnect", "alwaysOnTop"].contains(key) {
            defaults.set(value, forKey: key)
        }
        defaults.set(cleanName, forKey: "receiverName")
        defaults.set(path.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "receiverPath")
    }

    // Native menus use the same owned receiver while the window is hidden.
    func disconnect() {
        guard status == "streaming" else { return }
        restartAfterStop = true
        stop()
    }
    private var restartAfterStop = false

    private func executable(_ name: String) -> String? {
        let roots = ["/opt/homebrew/bin", "/usr/local/bin",
                     "/Library/Frameworks/GStreamer.framework/Commands"]
        return roots.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func environment(scanning: Bool = false) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["GST_DEBUG"] = "1"
        env["GST_DEBUG_NO_COLOR"] = "1"
        if let workspace = pluginWorkspace {
            // Isolate required plugins; never scan the system's optional Python/GTK set.
            env["GST_PLUGIN_SYSTEM_PATH"] = ""
            env["GST_PLUGIN_SYSTEM_PATH_1_0"] = ""
            env["GST_PLUGIN_PATH"] = workspace.appendingPathComponent("plugins").path
            env["GST_PLUGIN_PATH_1_0"] = workspace.appendingPathComponent("plugins").path
            env["GST_REGISTRY"] = workspace.appendingPathComponent("registry.bin").path
            env["GST_REGISTRY_1_0"] = workspace.appendingPathComponent("registry.bin").path
            // Scan in the owned probe process so timeout cannot orphan a scanner child.
            if scanning { env["GST_REGISTRY_FORK"] = "no" }
            else { env.removeValue(forKey: "GST_REGISTRY_FORK") }
        }
        return env
    }

    private func preparePlugins(inspector: String) throws {
        if pluginWorkspace != nil { return }
        let resolved = URL(fileURLWithPath: inspector).resolvingSymlinksInPath()
        let prefix = resolved.deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [prefix.appendingPathComponent("lib/gstreamer-1.0"),
                          prefix.appendingPathComponent("Libraries/gstreamer-1.0"),
                          URL(fileURLWithPath: "/Library/Frameworks/GStreamer.framework/Libraries/gstreamer-1.0")]
        guard let source = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("libgstcoreelements.dylib").path)
        }) else {
            // Tests inject a no-op inspector; production always requires a plugin directory.
            if inspectorOverride != nil { return }
            throw ReceiverFailure(message: "找不到 GStreamer 插件目录。请使用官方 Homebrew 或 macOS framework 安装。")
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("airplay-receiver-" + UUID().uuidString)
        let plugins = workspace.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        do {
            let names = ["coreelements", "app", "playback", "typefindfunctions", "videoparsersbad",
                         "libav", "audioconvert", "audioresample", "videoconvertscale",
                         "osxaudio", "autodetect", "volume", "level"]
            for name in names {
                let filename = "libgst\(name).dylib"
                let original = source.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: original.path) {
                    try FileManager.default.createSymbolicLink(at: plugins.appendingPathComponent(filename),
                                                              withDestinationURL: original)
                }
            }
            pluginWorkspace = workspace
            log("仅扫描 13 类必要 GStreamer 插件；使用独立临时 registry")
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    private func probe(_ path: String, _ args: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.environment = environment(scanning: true)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        let deadline = Date().addingTimeInterval(6)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
            task.waitUntilExit()
            throw ReceiverFailure(message: "依赖检查超时：\(URL(fileURLWithPath: path).lastPathComponent)")
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw ReceiverFailure(message: "依赖不可用：\(URL(fileURLWithPath: path).lastPathComponent) \(args.joined(separator: " "))。请检查 GStreamer 插件与动态库。")
        }
    }

    func check(path: String) throws -> String {
        let receiver = path.isEmpty ? bundledPath : path
        guard receiver.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: receiver) else {
            throw ReceiverFailure(message: "找不到 UxPlay 接收核心。请在项目目录运行 ./scripts/build_receiver.sh，然后重新构建应用；也可指定已构建核心的绝对路径。")
        }
        guard let inspector = inspectorOverride ?? executable("gst-inspect-1.0") else {
            throw ReceiverFailure(message: "缺少 GStreamer。请安装官方 Homebrew gstreamer，或官方 macOS runtime + devel 包。")
        }
        try preparePlugins(inspector: inspector)
        try probe(receiver, ["-rc", "/dev/null", "-h"])
        for plugin in ["h264parse", "decodebin", "avdec_h264", "osxaudiosink", "avdec_aac", "avdec_alac", "appsrc", "appsink", "queue", "audioconvert", "audioresample", "volume", "level", "videoconvert", "videoscale"] {
            try probe(inspector, [plugin])
        }
        log("依赖检查通过：UxPlay + GStreamer 视频 / 音频插件")
        return receiver
    }

    func start(name: String, path: String) throws {
        // Duplicate commands are idempotent, including while startup is pending.
        guard process == nil else { return }
        try save(name: name, path: path)
        state("checking", "正在检查接收核心与播放依赖…")
        do {
            let receiver = try check(path: path.trimmingCharacters(in: .whitespacesAndNewlines))
            let task = Process()
            task.executableURL = URL(fileURLWithPath: receiver)
            guard let video = videoOutput else {
                throw ReceiverFailure(message: "内嵌视频引擎未就绪，请重新打开应用。")
            }
            task.arguments = ["-rc", "/dev/null", "-n", name.trimmingCharacters(in: .whitespacesAndNewlines),
                              "-nh", "-vsync", "-avdec", "-vs", "appsink", "-vc",
                              "videoconvert ! video/x-raw,format=BGRA", "-as", "osxaudiosink"]
            var childEnvironment = environment()
            childEnvironment["FLUTTER_AIRPLAY_FRAME_SOCKET"] = try video.begin()
            task.environment = childEnvironment
            task.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            generation += 1
            let token = generation
            stopping = false
            pending.removeAll()
            output = pipe
            process = task
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                self?.queue.async { [weak self] in
                    guard let self = self, self.generation == token else { return }
                    self.consume(data)
                }
            }
            task.terminationHandler = { [weak self] terminated in
                self?.queue.async { [weak self] in
                    guard let self = self, self.generation == token else { return }
                    self.finish(terminated)
                }
            }
            try task.run()
            log("播放路径：软件 H.264 解码 + Flutter 内嵌画面 + macOS 音频")
            log("同步策略：AirPlay 时间戳 + 共享系统时钟；音视频按 PTS 播放，无固定偏移")
            log("启动 UxPlay（PID \(task.processIdentifier)）；Bonjour，同局域网，动态端口")
            state("starting", "正在注册 Bonjour 接收服务…")
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self = self, self.generation == token, self.status == "starting" else { return }
                self.log("未收到接收核心 ready 事件。请确认使用本项目的已补丁核心，并检查局域网权限。")
                self.stop(finalError: "接收服务启动超时，请查看日志与局域网权限。")
            }
        } catch {
            videoOutput?.end()
            output?.fileHandleForReading.readabilityHandler = nil
            output = nil
            process = nil
            state("error", error.localizedDescription)
            log(error.localizedDescription)
            throw error
        }
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            receiveLine(line)
        }
        if pending.count > 16384 {
            log(String(decoding: pending.prefix(4096), as: UTF8.self))
            pending.removeAll()
        }
    }

    // Stable contract supplied by the maintained UxPlay source. No log-word guessing.
    func receiveLine(_ line: String) {
        guard !line.isEmpty else { return }
        log(line)
        guard !stopping, process != nil else { return }
        if line.hasPrefix("AIRPLAY_RECEIVER_EVENT client ") {
            clientName = String(line.dropFirst("AIRPLAY_RECEIVER_EVENT client ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            onEvent?(["type": "client", "name": clientName])
            if videoWidth == 0 { state("streaming", "已建立连接，等待第一帧画面") }
            return
        }
        switch line {
        case "AIRPLAY_RECEIVER_EVENT ready":
            state("waiting", "等待 iPhone · 请在控制中心选择此设备")
        case "AIRPLAY_RECEIVER_EVENT streaming":
            state("streaming", "已收到媒体流 · 画面显示后可确认连接成功")
        case "AIRPLAY_RECEIVER_EVENT waiting":
            videoOutput?.clear()
            state("waiting", "连接已结束 · 等待下一次投屏")
        default: break
        }
    }

    func videoDimensions(width: Int, height: Int) {
        videoWidth = width; videoHeight = height
        onEvent?(["type": "video", "textureId": videoOutput?.textureIdentifier ?? -1,
                  "videoWidth": width, "videoHeight": height])
    }

    private func finish(_ task: Process) {
        videoOutput?.end()
        output?.fileHandleForReading.readabilityHandler = nil
        if !pending.isEmpty { log(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        process = nil
        output = nil
        log("UxPlay 已退出（状态码 \(task.terminationStatus)）")
        if stopping {
            if status != "error" { state("stopped", "接收器已停止") }
        } else {
            state("error", "接收核心意外退出（\(task.terminationStatus)），请查看日志。")
        }
        stopping = false
        if restartAfterStop {
            restartAfterStop = false
            do { try start(name: defaults.string(forKey: "receiverName") ?? "Flutter AirPlay",
                           path: defaults.string(forKey: "receiverPath") ?? "") }
            catch { state("error", error.localizedDescription) }
        }
    }

    func stop(finalError: String? = nil) {
        guard let task = process else {
            if finalError == nil { state("stopped", "接收器未启动") }
            return
        }
        if stopping { return }
        stopping = true
        videoOutput?.end()
        if let detail = finalError { state("error", detail) }
        else { state("stopping", "正在停止接收器…") }
        if task.isRunning { task.terminate() }
        let token = generation
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.generation == token, task.isRunning else { return }
            self.log("接收核心未及时响应停止，终止本应用拥有的进程。")
            kill(task.processIdentifier, SIGKILL)
        }
    }

    // Called only during application termination; wait is bounded and owns only our PID.
    func shutdown() {
        queue.sync {
            restartAfterStop = false
            defer {
                videoOutput?.end()
                if let workspace = pluginWorkspace { try? FileManager.default.removeItem(at: workspace) }
                pluginWorkspace = nil
            }
            guard let task = process else { return }
            stopping = true
            if task.isRunning { task.terminate() }
            let deadline = Date().addingTimeInterval(3)
            while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            output?.fileHandleForReading.readabilityHandler = nil
            process = nil
            output = nil
        }
    }
}
