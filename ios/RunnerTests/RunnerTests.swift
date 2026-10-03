// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var host: ReceiverHost!

    override func setUpWithError() throws {
        suiteName = "org.flutterairplay.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // Launch arguments disable reception in the real test application;
        // the isolated suite should exercise persisted settings independently.
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        defaults.removePersistentDomain(forName: suiteName)
        host = ReceiverHost(defaults: defaults)
    }

    override func tearDownWithError() throws {
        host.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
        host = nil
        defaults = nil
        suiteName = nil
    }

    func testSnapshotDescribesForegroundEmbeddedReceiver() {
        let snapshot = host.queue.sync { host.snapshot() }
        XCTAssertEqual(snapshot["status"] as? String, "stopped")
        XCTAssertEqual((snapshot["pid"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(snapshot["name"] as? String, "Flutter AirPlay")
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
        XCTAssertNil(defaults.data(forKey: "receiverIdentity"))
    }

    func testSaveTrimsNameAndPersistsPreferencesWithoutStarting() throws {
        try host.queue.sync {
            try host.save(name: "  Test iPad \n", path: " \n", autoStart: false)
        }
        let snapshot = host.queue.sync { host.snapshot() }
        XCTAssertEqual(snapshot["name"] as? String, "Test iPad")
        XCTAssertEqual(snapshot["autoStart"] as? Bool, false)
        XCTAssertEqual(snapshot["status"] as? String, "stopped")
        XCTAssertEqual((snapshot["pid"] as? NSNumber)?.intValue, 0)
        XCTAssertNil(defaults.data(forKey: "receiverIdentity"))
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
            XCTAssertEqual(defaults.string(forKey: "receiverName"), accepted)
            XCTAssertEqual(defaults.object(forKey: "receiverAutoStart") as? Bool, false)
        }
        let acceptedUnicode = String(repeating: "中", count: 16) + "ab"
        XCTAssertEqual(acceptedUnicode.utf8.count, 50)
        try host.queue.sync { try host.save(name: acceptedUnicode, path: "") }
        XCTAssertEqual(defaults.string(forKey: "receiverName"), acceptedUnicode)
    }

    func testExecutablePathFailsWithoutChangingSavedPreferences() throws {
        try host.queue.sync { try host.save(name: "Saved iPad", path: "", autoStart: false) }
        XCTAssertThrowsError(try host.queue.sync {
            try host.save(name: "Replacement", path: "/tmp/receiver", autoStart: true)
        })
        XCTAssertThrowsError(try host.queue.sync { try host.check(path: "/tmp/receiver") })
        XCTAssertEqual(defaults.string(forKey: "receiverName"), "Saved iPad")
        XCTAssertEqual(defaults.object(forKey: "receiverAutoStart") as? Bool, false)
    }

    func testBackgroundStartFailsBeforeCreatingMediaOrReceiver() {
        let video = TestVideoOutput()
        host.queue.sync {
            host.videoOutput = video
            host.foreground = false
        }
        XCTAssertThrowsError(try host.queue.sync { try host.start(name: "Test iPad", path: "") })
        XCTAssertEqual(video.beginCount, 0)
        XCTAssertNil(defaults.string(forKey: "receiverName"))
        XCTAssertNil(defaults.data(forKey: "receiverIdentity"))
        let snapshot = host.queue.sync { host.snapshot() }
        XCTAssertEqual(snapshot["status"] as? String, "stopped")
        XCTAssertEqual((snapshot["pid"] as? NSNumber)?.intValue, 0)
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
        XCTAssertNil(defaults.data(forKey: "receiverIdentity"))
    }
}

private final class TestVideoOutput: ReceiverVideoOutput {
    let textureIdentifier: Int64 = 99
    private(set) var beginCount = 0
    func begin() throws { beginCount += 1 }
    func receive(_ frame: CVPixelBuffer) {}
    func clear() {}
    func end() {}
}
