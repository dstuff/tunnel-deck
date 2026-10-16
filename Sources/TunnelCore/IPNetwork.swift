import Foundation
import Darwin

/// Numeric addresses only. The same matcher is used by validation and the address inspector.
public struct IPNetwork: Equatable, Sendable {
    public let bytes: [UInt8]
    public let prefix: Int

    public init(_ text: String) throws {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let address = Self.address(String(parts[0])) else {
            throw VPNError("Введите корректный IP-адрес или подсеть, например 10.20.0.0/16.")
        }
        let bits = address.count * 8
        let width = parts.count == 2 ? Int(parts[1]) : bits
        guard let width, (0...bits).contains(width) else { throw VPNError("Некорректная длина префикса подсети.") }
        prefix = width
        bytes = address.enumerated().map { index, byte in
            let remaining = width - index * 8
            return remaining >= 8 ? byte : remaining <= 0 ? 0 : byte & (0xff << (8 - remaining))
        }
    }

    public static func address(_ text: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        if text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }

    public var cidr: String {
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { _ = inet_ntop(bytes.count == 4 ? AF_INET : AF_INET6, $0.baseAddress, &output, socklen_t(output.count)) }
        return String(cString: output) + "/\(prefix)"
    }

    public func contains(_ address: String) -> Bool {
        guard let candidate = Self.address(address), candidate.count == bytes.count else { return false }
        for index in bytes.indices {
            let remaining = prefix - index * 8
            if remaining <= 0 { break }
            let mask: UInt8 = remaining >= 8 ? 0xff : 0xff << (8 - remaining)
            if candidate[index] & mask != bytes[index] { return false }
        }
        return true
    }

    public static func prefixLength(netmask: String) throws -> Int {
        guard let bytes = address(netmask) else { throw VPNError("Сервер передал некорректную маску сети.") }
        var count = 0, ended = false
        for byte in bytes {
            for bit in (0...7).reversed() {
                if byte & (1 << bit) != 0 {
                    guard !ended else { throw VPNError("Сервер передал некорректную маску сети.") }
                    count += 1
                } else { ended = true }
            }
        }
        return count
    }
}
