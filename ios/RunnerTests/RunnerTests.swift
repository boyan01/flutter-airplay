// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import XCTest
import AVFAudio
import UIKit
@testable import Runner

final class RunnerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var host: ReceiverHost!
    private var support: URL!

    override func setUpWithError() throws {
        let active = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            UIApplication.shared.applicationState == .active
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 5), .completed)
        suiteName = "tech.soit.flutterairplay.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // Launch arguments disable reception in the real test application;
        // the isolated suite should exercise persisted settings independently.
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        defaults.removePersistentDomain(forName: suiteName)
        support = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        host = ReceiverHost(defaults: defaults, supportDirectory: support)
    }

    override func tearDownWithError() throws {
        host.shutdown()
        try? FileManager.default.removeItem(at: support)
        defaults.removePersistentDomain(forName: suiteName)
        host = nil
        defaults = nil
        suiteName = nil
    }

    func testSnapshotDescribesForegroundEmbeddedReceiver() {
        let snapshot = host.queue.sync { host.snapshot() }
        XCTAssertEqual(snapshot["status"] as? String, "stopped")
        XCTAssertEqual((snapshot["pid"] as? NSNumber)?.intValue, 0)
        let name = snapshot["name"] as? String
        XCTAssertNil(defaults.string(forKey: "receiverName"))
        XCTAssertEqual(name, snapshot["defaultName"] as? String)
        XCTAssertFalse(name?.isEmpty ?? true)
        XCTAssertLessThanOrEqual(name?.utf8.count ?? 0, 50)
        XCTAssertEqual(snapshot["path"] as? String, "")
        XCTAssertEqual((snapshot["textureId"] as? NSNumber)?.int64Value, -1)
        XCTAssertEqual(snapshot["autoStart"] as? Bool, true)
        XCTAssertEqual(snapshot["audioPlaying"] as? Bool, false)
        XCTAssertEqual(snapshot["videoPaused"] as? Bool, false)
        let capabilities = snapshot["capabilities"] as? [String: Any]
        XCTAssertEqual(capabilities?["platform"] as? String, "ios")
        XCTAssertEqual(capabilities?["supportsExecutablePath"] as? Bool, false)
        XCTAssertEqual(capabilities?["supportsLaunchAtLogin"] as? Bool, false)
        XCTAssertEqual(capabilities?["foregroundOnly"] as? Bool, true)
        XCTAssertEqual(defaults.data(forKey: "receiverIdentity")?.count, 6)
    }

    func testVideoQualityChangesRuntimeAndControlsRequestedSize() throws {
        try host.queue.sync {
            host.screenSize = (width: 2732, height: 2048)
            try host.save(name: "Quality iPad", path: "", videoQuality: "auto")
            XCTAssertEqual(host.requestedVideoSize().height, 2048)
            host.screenSize = (width: 3840, height: 2670)
            XCTAssertEqual(host.requestedVideoSize().height, 2160)
            for (quality, width, height) in [("720", 1280, 720), ("1080", 1920, 1080),
                                            ("1440", 2560, 1440), ("2160", 3840, 2160)] {
                try host.save(name: "Quality iPad", path: "", videoQuality: quality)
                XCTAssertNil(defaults.string(forKey: "videoQuality"))
                XCTAssertEqual(host.requestedVideoSize().width, width)
                XCTAssertEqual(host.requestedVideoSize().height, height)
            }
            XCTAssertThrowsError(try host.save(name: "Rejected", path: "", videoQuality: "invalid"))
            XCTAssertEqual(host.snapshot()["name"] as? String, "Quality iPad")
            XCTAssertEqual(host.snapshot()["videoQuality"] as? String, "2160")
        }
    }

    func testSaveTrimsNameWithoutPersistingOrStarting() throws {
        let defaultName = host.queue.sync { host.snapshot()["defaultName"] as? String }
        XCTAssertFalse(try host.queue.sync { try host.applySettings() })
        try host.queue.sync {
            try host.save(name: "  Test iPad \n", path: " \n", autoStart: false)
        }
        let snapshot = host.queue.sync { host.snapshot() }
        XCTAssertEqual(snapshot["name"] as? String, "Test iPad")
        XCTAssertEqual(snapshot["defaultName"] as? String, defaultName)
        XCTAssertEqual(snapshot["autoStart"] as? Bool, false)
        XCTAssertEqual(snapshot["status"] as? String, "stopped")
        XCTAssertEqual((snapshot["pid"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(defaults.data(forKey: "receiverIdentity")?.count, 6)
    }

    func testSaveValidatesUTF8ByteLimitAndControlCharacters() throws {
        let accepted = String(repeating: "a", count: 50)
        try host.queue.sync { try host.save(name: accepted, path: "", autoStart: false) }
        // Seventeen three-byte scalars exceed the limit despite fewer than 50 characters.
        for invalid in [" \n ", String(repeating: "a", count: 51),
                        String(repeating: "中", count: 17), "Test\tReceiver", "Test\u{0000}Receiver"] {
            XCTAssertThrowsError(try host.queue.sync {
                try host.save(name: invalid, path: "", autoStart: true)
            }, "Invalid name was accepted: \(invalid.debugDescription)")
            XCTAssertEqual(host.snapshot()["name"] as? String, accepted)
            XCTAssertEqual(host.snapshot()["autoStart"] as? Bool, false)
        }
        let acceptedUnicode = String(repeating: "中", count: 16) + "ab"
        XCTAssertEqual(acceptedUnicode.utf8.count, 50)
        try host.queue.sync { try host.save(name: acceptedUnicode, path: "") }
        XCTAssertEqual(host.snapshot()["name"] as? String, acceptedUnicode)
    }

    func testExecutablePathFailsWithoutChangingSavedPreferences() throws {
        try host.queue.sync { try host.save(name: "Saved iPad", path: "", autoStart: false) }
        XCTAssertThrowsError(try host.queue.sync {
            try host.save(name: "Replacement", path: "/tmp/receiver", autoStart: true)
        })
        XCTAssertThrowsError(try host.queue.sync { try host.check(path: "/tmp/receiver") })
        XCTAssertEqual(host.snapshot()["name"] as? String, "Saved iPad")
        XCTAssertEqual(host.snapshot()["autoStart"] as? Bool, false)
    }

    func testBackgroundStartFailsBeforeCreatingMediaOrReceiver() {
        let video = TestVideoOutput()
        let initialName = defaults.string(forKey: "receiverName")
        XCTAssertNil(defaults.data(forKey: "receiverIdentity"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        host.queue.sync {
            host.videoOutput = video
            // The request's current state must override an older scene flag.
            host.foreground = true
        }
        XCTAssertThrowsError(try host.queue.sync { try host.start(name: "Test iPad", path: "", foreground: false) })
        XCTAssertEqual(video.beginCount, 0)
        XCTAssertEqual(defaults.string(forKey: "receiverName"), initialName)
        // Rejection precedes lazy bootstrap, so it must not create an identity
        // or support directory. A later snapshot may bootstrap the receiver.
        XCTAssertNil(defaults.data(forKey: "receiverIdentity"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        let snapshot = host.queue.sync { host.snapshot() }
        XCTAssertEqual(snapshot["status"] as? String, "stopped")
        XCTAssertEqual((snapshot["pid"] as? NSNumber)?.intValue, 0)
    }

    func testStartUsesForegroundRequestBeforeSceneActivationCallback() {
        let video = TestVideoOutput()
        video.beginError = ReceiverFailure(message: "Foreground request reached video output")
        host.queue.sync {
            host.videoOutput = video
            // Engine installation can precede activation; the method request
            // carries the newer application state observed on the main thread.
            host.foreground = false
        }
        XCTAssertThrowsError(try host.queue.sync {
            try host.start(name: "Test iPad", path: "", foreground: true)
        }) { error in
            XCTAssertEqual(error.localizedDescription, "Foreground request reached video output")
        }
        XCTAssertEqual(video.beginCount, 1)
        XCTAssertTrue(host.queue.sync { host.foreground })
        XCTAssertEqual(host.queue.sync { host.snapshot()["status"] as? String }, "error")
        XCTAssertEqual(defaults.data(forKey: "receiverIdentity")?.count, 6)
    }

    func testForegroundResumeRetriesActivationAfterBackgroundAudioInterruption() throws {
        let bridge = ReceiverBridge()
        let receiver = bridge.host
        let video = TestVideoOutput()
        func onMain(_ action: () -> Void) {
            if Thread.isMainThread { action() }
            else { DispatchQueue.main.sync(execute: action) }
        }
        defer {
            onMain {
                bridge.handleInterruption(Notification(name: AVAudioSession.interruptionNotification,
                    object: AVAudioSession.sharedInstance(), userInfo: [
                        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                        AVAudioSessionInterruptionOptionKey: UInt(0)
                    ]))
            }
            receiver.queue.sync { receiver.userStop() }
        }
        try receiver.queue.sync {
            XCTAssertEqual(receiver.snapshot()["status"] as? String, "stopped")
            receiver.videoOutput = video
            // Keep this synthetic receiver private while exercising the real
            // interruption handler, audio activation and native lifecycle.
            receiver.publish = { _, _, _, _, _, _ in }
            try receiver.start(name: receiver.snapshot()["name"] as? String ?? "Flutter AirPlay",
                               path: "", foreground: true)
        }
        onMain {
            bridge.handleInterruption(Notification(name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(), userInfo: [
                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
                ]))
        }
        XCTAssertEqual(receiver.queue.sync { receiver.snapshot()["status"] as? String }, "stopped")
        onMain { bridge.resume() }
        let resumed = receiver.queue.sync { receiver.snapshot() }
        XCTAssertEqual(resumed["status"] as? String, "starting")
        XCTAssertGreaterThan((resumed["pid"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertEqual(video.beginCount, 2)
    }

    func testFailedResumeKeepsReceiveIntentUntilSuccessOrUserStop() throws {
        let video = TestVideoOutput()
        try host.queue.sync {
            host.videoOutput = video
            host.publish = { _, _, _, _, _, _ in }
            try host.start(name: "Test iPad", path: "", foreground: true)
            host.suspend()
            video.beginError = ReceiverFailure(message: "Temporary activation failure")
            host.resume()
            XCTAssertEqual(host.snapshot()["status"] as? String, "error")
            XCTAssertEqual(video.beginCount, 2)
            video.beginError = nil
            host.resume()
            XCTAssertEqual(host.snapshot()["status"] as? String, "starting")
            XCTAssertGreaterThan((host.snapshot()["pid"] as? NSNumber)?.intValue ?? 0, 0)
            XCTAssertEqual(video.beginCount, 3)
            host.suspend()
            video.beginError = ReceiverFailure(message: "Temporary activation failure")
            host.resume()
            XCTAssertEqual(video.beginCount, 4)
            host.userStop()
            video.beginError = nil
            host.resume()
            XCTAssertEqual((host.snapshot()["pid"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual(video.beginCount, 4)
        }
    }

    func testIdleSuspendResumeDoesNotStartReceiver() {
        let video = TestVideoOutput()
        host.queue.sync {
            host.videoOutput = video
            host.suspend()
            XCTAssertFalse(host.foreground)
            host.resume()
            XCTAssertTrue(host.foreground)
            XCTAssertFalse(host.isCurrent(0))
        }
        XCTAssertEqual(video.beginCount, 0)
        XCTAssertEqual(host.queue.sync { host.snapshot()["status"] as? String }, "stopped")
        XCTAssertEqual(defaults.data(forKey: "receiverIdentity")?.count, 6)
    }
}

private final class TestVideoOutput: ReceiverVideoOutput {
    let textureIdentifier: Int64 = 99
    private(set) var beginCount = 0
    var beginError: Error?
    func begin() throws {
        beginCount += 1
        if let error = beginError { throw error }
    }
    func receive(_ frame: CVPixelBuffer, deadline: Int64) {}
    func clear() {}
    func end() {}
}
