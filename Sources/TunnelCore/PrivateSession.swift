import TunnelLocalization
import Foundation
import Darwin

public final class PrivateSession {
    public let directory: URL
    public var requestFile: URL { directory.appendingPathComponent("request.json") }
    public var eventFile: URL { directory.appendingPathComponent("events.jsonl") }
    public var controlFile: URL { directory.appendingPathComponent("control") }
    private var controlFD: Int32 = -1
    private var leaseFD: Int32 = -1

    public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        directory = temporaryDirectory.appendingPathComponent("tunneldeck-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var initialized = false
        defer {
            if !initialized {
                if controlFD >= 0 { close(controlFD); controlFD = -1 }
                if leaseFD >= 0 { close(leaseFD); leaseFD = -1 }
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let lease = directory.appendingPathComponent("lease")
        try Self.write(Data(), to: lease)
        leaseFD = open(lease.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard leaseFD >= 0, flock(leaseFD, LOCK_SH | LOCK_NB) == 0 else {
            throw VPNError(L10n.message("privatesession.could_not_retain_the_vpn_session_directory"))
        }
        try Self.write(Data(), to: eventFile)
        guard mkfifo(controlFile.path, 0o600) == 0 else { throw VPNError(L10n.message("privatesession.could_not_create_the_vpn_control_channel")) }
        controlFD = open(controlFile.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW)
        guard controlFD >= 0 else { throw VPNError(L10n.message("privatesession.could_not_open_the_vpn_control_channel")) }
        initialized = true
    }
    public static func write(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw VPNError(L10n.message("privatesession.could_not_write_the_temporary_configuration"))
        }
    }
    public func save(_ request: TunnelRequest) throws {
        let data = try JSONEncoder().encode(request)
        guard data.count <= 512_000 else { throw VPNError(L10n.message("privatesession.the_profile_and_routing_rules_exceed_the_request_size")) }
        try Self.write(data, to: requestFile)
    }
    public func stop() { if controlFD >= 0 { _ = "stop\n".withCString { Darwin.write(controlFD, $0, 5) } } }
    public func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Only delete our directories when neither the UI nor helper holds a lease.
    @discardableResult
    public static func removeAbandoned(in root: URL = FileManager.default.temporaryDirectory) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("tunneldeck-"), UUID(uuidString: String(name.dropFirst("tunneldeck-".count))) != nil else { continue }
            let directoryFD = open(entry.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directoryFD >= 0 else { continue }
            defer { close(directoryFD) }
            var directoryInfo = stat()
            guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
                  directoryInfo.st_mode & 0o077 == 0 else { continue }
            let lease = openat(directoryFD, "lease", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard lease >= 0 else { continue }
            defer { close(lease) }
            var info = stat()
            guard fstat(lease, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  flock(lease, LOCK_EX | LOCK_NB) == 0 else { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    deinit {
        if controlFD >= 0 { close(controlFD) }
        if leaseFD >= 0 { close(leaseFD) }
    }
}
