import TunnelLocalization
import Foundation
import TunnelCore

private final class OutputBuffer {
    private let lock = NSLock()
    private var bytes = Data()
    private var pending = Data()
    let callback: ((LocalizedMessage) -> Void)?
    init(callback: ((LocalizedMessage) -> Void)? = nil) { self.callback = callback }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.count < 1_000_000 { bytes.append(data) }
        guard let callback else { return }
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            if !line.isEmpty { callback(.verbatim(line)) }
        }
        if pending.count > 64_000 { pending.removeAll(); callback(L10n.message("processrunner.a_long_line_was_hidden")) }
    }
    func finish() -> Data {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { callback?(.verbatim(String(decoding: pending, as: UTF8.self))); pending.removeAll() }
        return bytes
    }
}

struct ProcessOutput { let status: Int32; let stdout: String; let stderr: String }

@MainActor final class ProcessRunner {
    private var process: Process?
    func cancel() { if let process, process.isRunning { process.terminate() } }

    func run(_ executable: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval = 45,
             logStandardOutput: Bool = false, log: ((LocalizedMessage) -> Void)? = nil) async throws -> ProcessOutput {
        let child = Process(), output = Pipe(), errors = Pipe(), stdin = Pipe()
        let stdout = OutputBuffer(callback: logStandardOutput ? log : nil), stderr = OutputBuffer(callback: log)
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.standardOutput = output; child.standardError = errors
        child.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        child.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        output.fileHandleForReading.readabilityHandler = { handle in stdout.append(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { handle in stderr.append(handle.availableData) }
        process = child
        defer { process = nil }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let watchdog = DispatchWorkItem { if child.isRunning { child.terminate() } }
                child.terminationHandler = { process in
                    watchdog.cancel()
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    stdout.append(output.fileHandleForReading.readDataToEndOfFile())
                    stderr.append(errors.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: ProcessOutput(status: process.terminationStatus,
                        stdout: String(decoding: stdout.finish(), as: UTF8.self), stderr: String(decoding: stderr.finish(), as: UTF8.self)))
                }
                do {
                    try child.run()
                    if let input {
                        try? stdin.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8))
                        try? stdin.fileHandleForWriting.close()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                } catch {
                    child.terminationHandler = nil
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    if child.isRunning { child.terminate() }
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: { if child.isRunning { child.terminate() } })
    }
}
