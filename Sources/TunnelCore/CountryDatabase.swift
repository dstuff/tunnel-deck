import Foundation

/// A read-only, memory-mapped range index generated from the exact same input as geoip.dat.
public struct CountryDatabase: Sendable {
    private let data: Data
    private let count4: Int
    private let count6: Int
    public let version: String
    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }
    public init(data: Data) throws {
        guard data.count >= 24, data.prefix(8) == Data("TDGEO001".utf8), data[15] == 0 else { throw VPNError("База стран повреждена.") }
        func number(_ offset: Int) -> Int { data[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) } }
        let n4 = number(16), n6 = number(20)
        guard n4 <= 5_000_000, n6 <= 5_000_000, data.count == 24 + n4 * 10 + n6 * 34 else { throw VPNError("Неподдерживаемая база стран.") }
        self.data = data; count4 = n4; count6 = n6
        version = String(decoding: data[8..<15], as: UTF8.self)
    }
    public func country(for address: String) -> String? {
        guard let ip = IPNetwork.address(address) else { return nil }
        let width = ip.count, stride = width * 2 + 2
        let base = width == 4 ? 24 : 24 + count4 * 10
        var low = 0, high = width == 4 ? count4 : count6
        while low < high {
            let mid = (low + high) / 2, offset = base + mid * stride
            let start = data[offset..<offset+width], end = data[offset+width..<offset+width*2]
            if ip.lexicographicallyPrecedes(start) { high = mid }
            else if end.lexicographicallyPrecedes(ip) { low = mid + 1 }
            else { return String(decoding: data[offset+width*2..<offset+stride], as: UTF8.self) }
        }
        return nil
    }
}
