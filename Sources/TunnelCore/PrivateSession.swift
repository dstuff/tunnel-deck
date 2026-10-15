import Foundation
import Darwin

public final class PrivateSession {
    public let directory: URL
    public var requestFile: URL { directory.appendingPathComponent("request.json") }
    public var eventFile: URL { directory.appendingPathComponent("events.jsonl") }
    public var controlFile: URL { directory.appendingPathComponent("control") }
    private var controlFD: Int32 = -1

    public init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunneldeck-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Self.write(Data(), to: eventFile)
        guard mkfifo(controlFile.path, 0o600) == 0 else { throw VPNError("Не удалось создать канал управления VPN.") }
        controlFD = open(controlFile.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW)
        guard controlFD >= 0 else { throw VPNError("Не удалось открыть канал управления VPN.") }
    }
    public static func write(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw VPNError("Не удалось записать временную конфигурацию.")
        }
    }
    public func save(_ request: TunnelRequest) throws { try Self.write(JSONEncoder().encode(request), to: requestFile) }
    public func stop() { if controlFD >= 0 { _ = "stop\n".withCString { Darwin.write(controlFD, $0, 5) } } }
    public func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { if controlFD >= 0 { close(controlFD) } }
}
