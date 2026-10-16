import XCTest
import Darwin
@testable import TunnelCore

final class PrivateSessionTests: XCTestCase {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tunneldeck-cleanup-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testCleanupKeepsActiveSessionAndRemovesItAfterOwnerExits() throws {
        try withRoot { root in
            var session: PrivateSession? = try PrivateSession(temporaryDirectory: root)
            let directory = session!.directory
            XCTAssertEqual(PrivateSession.removeAbandoned(in: root), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            session = nil // Simulate an exit without the normal remove().
            XCTAssertEqual(PrivateSession.removeAbandoned(in: root), 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testCleanupWaitsForHelperEvenAfterUIExits() throws {
        try withRoot { root in
            var session: PrivateSession? = try PrivateSession(temporaryDirectory: root)
            let directory = session!.directory
            let helperLease = open(directory.appendingPathComponent("lease").path, O_RDONLY | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(helperLease, 0)
            XCTAssertEqual(flock(helperLease, LOCK_SH | LOCK_NB), 0)
            session = nil
            XCTAssertEqual(PrivateSession.removeAbandoned(in: root), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            close(helperLease)
            XCTAssertEqual(PrivateSession.removeAbandoned(in: root), 1)
        }
    }

    func testCleanupSkipsUnrelatedDirectoriesLegacySessionsAndSymlinks() throws {
        try withRoot { root in
            let manager = FileManager.default
            let unrelated = root.appendingPathComponent("tunneldeck-unrelated")
            let legacy = root.appendingPathComponent("tunneldeck-\(UUID())")
            let link = root.appendingPathComponent("tunneldeck-\(UUID())")
            for directory in [unrelated, legacy] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try PrivateSession.write(Data(), to: unrelated.appendingPathComponent("lease"))
            try manager.createSymbolicLink(at: link, withDestinationURL: unrelated)
            XCTAssertEqual(PrivateSession.removeAbandoned(in: root), 0)
            for directory in [unrelated, legacy, link] {
                XCTAssertTrue(manager.fileExists(atPath: directory.path))
            }
        }
    }
}
