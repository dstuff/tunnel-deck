import XCTest
import TunnelLocalization
@testable import TunnelCore

final class LocalizedEventTests: XCTestCase {
    func testLegacyMalformedAndUnknownDescriptorsKeepLifecycleEvents() throws {
        let legacy = TunnelEvent(.networkReady, "legacy fallback")
        let decoder = JSONDecoder()
        let data = try JSONEncoder().encode(legacy)
        XCTAssertNil(try decoder.decode(TunnelEvent.self, from: data).localizedMessage)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["localizedMessage"] = ["key": "future", "arguments": "new unsupported shape"]
        let malformed = try decoder.decode(TunnelEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(malformed.kind, .networkReady)
        XCTAssertEqual(malformed.message, "legacy fallback")
        XCTAssertNil(malformed.localizedMessage)
        var future = legacy
        future.localizedMessage = LocalizedMessage(key: "future.key")
        let decoded = try decoder.decode(TunnelEvent.self, from: JSONEncoder().encode(future))
        XCTAssertEqual(decoded.localizedMessage?.resolve(language: .russian), "legacy fallback")
        XCTAssertEqual(decoded.kind, .networkReady)
    }

    func testWrongArgumentTypeUsesFallbackWithoutFormatting() {
        let wrongType = LocalizedMessage(key: "routing.country_name", arguments: [.integer(42)], fallback: "safe fallback")
        XCTAssertEqual(wrongType.resolve(language: .russian), "safe fallback")
        let missing = LocalizedMessage(key: "routingpolicy.rule", fallback: "safe fallback")
        XCTAssertEqual(missing.resolve(language: .englishUS), "safe fallback")
    }

    func testNestedSecretsAreRedactedBeforeEventEncoding() throws {
        let secret = "synthetic-secret-value"
        let inner = LocalizedMessage(key: "future.key", arguments: [.string(secret)], fallback: secret)
        let message = L10n.message("appmodel.could_not_save_settings", [.message(inner)])
        let redacted = LogRedactor(values: [secret]).redact(message)
        let event = TunnelEvent(.error, redacted)
        let data = try JSONEncoder().encode(event)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        XCTAssertTrue(redacted.resolve(language: .russian).contains("<redacted>"))
        XCTAssertTrue(redacted.resolve(language: .englishUS).contains("<redacted>"))
        let decoded = try JSONDecoder().decode(TunnelEvent.self, from: data)
        XCTAssertEqual(decoded.timestamp, event.timestamp)
        XCTAssertEqual(decoded.kind, .error)
    }

    func testOversizedStructuredPayloadFallsBackWithinJournalLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("localized-journal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        try PrivateSession.write(Data(), to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let writer = try SessionEventLog.Writer(fileDescriptor: handle.fileDescriptor, maximumBytes: 4096)
        let reader = try SessionEventLog.Reader(file: file)
        let message = LocalizedMessage(key: "future.key", arguments: [.string(String(repeating: "\"\n🧭", count: 20_000))], fallback: "bounded fallback")
        try writer.append(TunnelEvent(.networkReady, message))
        let event = try XCTUnwrap(reader.readAvailable().last)
        XCTAssertEqual(event.kind, .networkReady)
        XCTAssertEqual(event.message, "bounded fallback")
        XCTAssertNil(event.localizedMessage)
        XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 4096)
    }
}
