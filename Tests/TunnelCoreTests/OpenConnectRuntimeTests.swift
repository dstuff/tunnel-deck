import XCTest
@testable import TunnelCore

final class OpenConnectRuntimeTests: XCTestCase {
    func testOpenConnectRequiresBundledEngineAndExecutableNetworkScript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TunnelDeck runtime " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("openconnect"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RuntimePaths(root: root)
        // Even a development Mac with Homebrew must not mask an incomplete app.
        XCTAssertNil(paths.openconnect)
        XCTAssertNil(paths.vpncScript)
        XCTAssertThrowsError(try paths.check(.openConnect))

        let engine = root.appendingPathComponent("bin/openconnect")
        let script = root.appendingPathComponent("openconnect/vpnc-script")
        try Data().write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        XCTAssertEqual(paths.openconnect, engine.path)
        XCTAssertThrowsError(try paths.check(.openConnect))
        try Data().write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        XCTAssertThrowsError(try paths.check(.openConnect))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertEqual(paths.vpncScript, script.path)
        XCTAssertNoThrow(try paths.check(.openConnect))
    }
}
