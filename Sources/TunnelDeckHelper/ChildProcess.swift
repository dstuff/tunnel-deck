import Foundation
import Darwin
import TunnelCore

func environment(runtime: RuntimePaths) -> [String: String] {
    ["PATH": runtime.root.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
     "HOME": "/var/root", "LC_ALL": "C", "XRAY_LOCATION_ASSET": runtime.root.appendingPathComponent("xray").path]
}

@discardableResult
func tool(_ executable: String, _ arguments: [String], input: Data? = nil,
          env: [String: String]? = nil, allowFailure: Bool = false) throws -> String {
    let process = Process(), output = Pipe(), stdin = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = output; process.standardError = output
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
    process.environment = env ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    try process.run()
    if let input { try stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() }
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit(); watchdog.cancel()
    let text = String(decoding: data, as: UTF8.self)
    if process.terminationStatus != 0 && !allowFailure { throw VPNError(text.isEmpty ? "Сетевая команда завершилась с ошибкой." : text) }
    return text
}

final class EngineProcess {
    let process = Process()
    private let pipe = Pipe()
    private let lines: OutputLines
    private var started = false
    init(executable: String, arguments: [String], env: [String: String], input: String? = nil,
         session: SecureSession) throws {
        lines = OutputLines { session.emit(.log, $0) }
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = env; process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardOutput = pipe; process.standardError = pipe
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        pipe.fileHandleForReading.readabilityHandler = { [lines] handle in
            let data = handle.availableData
            if !data.isEmpty { lines.receive(data) }
        }
        try process.run()
        started = true
        if let input { try stdin.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8)); try? stdin.fileHandleForWriting.close() }
    }
    func stop() {
        guard started else { return }
        if process.isRunning { process.interrupt() }
        for _ in 0..<50 { if !process.isRunning { break }; usleep(100_000) }
        if process.isRunning { process.terminate() }
        for _ in 0..<30 { if !process.isRunning { break }; usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        lines.receive(pipe.fileHandleForReading.readDataToEndOfFile()); lines.finish()
        started = false
    }
    deinit { stop() }
}
