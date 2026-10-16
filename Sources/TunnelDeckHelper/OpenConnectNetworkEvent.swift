import Foundation
import Darwin
import TunnelCore

func writeOpenConnectNetworkEvent(directory path: String) throws {
    guard getuid() == 0, path.hasPrefix("/private/tmp/tunneldeck-root-"),
          UUID(uuidString: String(path.dropFirst("/private/tmp/tunneldeck-root-".count))) != nil else { throw VPNError("Недопустимый каталог сетевого события.") }
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw VPNError("Не удалось открыть каталог сетевого события.") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & 0o077 == 0 else { throw VPNError("Недопустимые права сетевого события.") }
    let event = try OpenConnectNetworkSettings(environment: ProcessInfo.processInfo.environment)
    guard ["connect", "reconnect", "attempt-reconnect", "disconnect"].contains(event.reason) else { return }
    let temporary = ".network-" + UUID().uuidString
    let output = openat(fd, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard output >= 0 else { throw VPNError("Не удалось записать сетевое событие.") }
    defer { close(output); unlinkat(fd, temporary, 0) }
    let handle = FileHandle(fileDescriptor: output, closeOnDealloc: false)
    try handle.write(contentsOf: JSONEncoder().encode(event)); try handle.synchronize()
    guard renameat(fd, temporary, fd, "openconnect-network.json") == 0 else { throw VPNError("Не удалось опубликовать сетевое событие.") }
}
