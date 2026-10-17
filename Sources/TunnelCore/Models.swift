import TunnelLocalization
import Foundation

public enum VPNProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case openConnect, amneziaWG, xray
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openConnect: return "OpenConnect"
        case .amneziaWG: return "AmneziaWG 3.1"
        case .xray: return "Xray"
        }
    }
    public var symbol: String {
        switch self {
        case .openConnect: return "shield"
        case .amneziaWG: return "waveform.path"
        case .xray: return "point.3.connected.trianglepath.dotted"
        }
    }
}

// Connection metadata stays separate from secrets in memory and in helper requests.
public struct VPNProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: VPNProtocol
    public var server: String
    public var username: String
    public var authGroup: String
    public var certificatePin: String
    public var disableDTLS: Bool
    public var xrayOutboundTag: String?

    public init(id: UUID = UUID(), name: String = L10n.text("connection.new"), kind: VPNProtocol = .openConnect,
                server: String = "", username: String = "", authGroup: String = "",
                certificatePin: String = "", disableDTLS: Bool = false, xrayOutboundTag: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.server = server
        self.username = username; self.authGroup = authGroup
        self.certificatePin = certificatePin; self.disableDTLS = disableDTLS
        self.xrayOutboundTag = xrayOutboundTag
    }
}

public struct ProfileSecrets: Codable, Sendable {
    public var password = ""
    public var camouflage = ""
    public var configuration = ""
    // Preserve unfinished input alongside secrets until it can be normalized.
    public var serverInput: String?
    public init() {}
}

public struct TunnelRequest: Codable, Sendable {
    public var userID: UInt32
    public var parentPID: Int32
    public var profile: VPNProfile
    public var secrets: ProfileSecrets
    public var cookie: String
    public var routing: RoutingPolicy
    public init(userID: UInt32, parentPID: Int32, profile: VPNProfile, secrets: ProfileSecrets, cookie: String = "", routing: RoutingPolicy = .init()) {
        self.userID = userID; self.parentPID = parentPID; self.profile = profile
        self.secrets = secrets; self.cookie = cookie
        self.routing = routing
    }
    private enum CodingKeys: String, CodingKey { case userID, parentPID, profile, secrets, cookie, routing }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UInt32.self, forKey: .userID); parentPID = try c.decode(Int32.self, forKey: .parentPID)
        profile = try c.decode(VPNProfile.self, forKey: .profile); secrets = try c.decode(ProfileSecrets.self, forKey: .secrets)
        cookie = try c.decodeIfPresent(String.self, forKey: .cookie) ?? ""
        routing = try c.decodeIfPresent(RoutingPolicy.self, forKey: .routing) ?? .init()
    }
}

public struct TunnelEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case log, configuring, routingReady, networkReady, connected, error, stopped }
    public var kind: Kind
    public var message: String
    public var timestamp: Date
    public var routing: RoutingRuntimeInfo?
    public var localizedMessage: LocalizedMessage?
    public init(_ kind: Kind, _ message: String, routing: RoutingRuntimeInfo? = nil) {
        self.kind = kind; self.message = message; self.timestamp = Date()
        self.routing = routing
        self.localizedMessage = nil
    }
    public init(_ kind: Kind, _ message: LocalizedMessage, routing: RoutingRuntimeInfo? = nil) {
        self.init(kind, message.resolve(language: .englishUS), routing: routing)
        self.localizedMessage = message
    }
    private enum CodingKeys: String, CodingKey { case kind, message, timestamp, routing, localizedMessage }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        message = try values.decode(String.self, forKey: .message)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        routing = try values.decodeIfPresent(RoutingRuntimeInfo.self, forKey: .routing)
        // An unsupported descriptor must never hide network readiness or cleanup.
        localizedMessage = try? values.decode(LocalizedMessage.self, forKey: .localizedMessage)
        if localizedMessage?.fallback == nil { localizedMessage?.fallback = message }
    }
}

public struct VPNError: LocalizedError, Sendable {
    public let localizedMessage: LocalizedMessage
    public var message: String { localizedMessage.resolve() }
    public init(_ message: String) { localizedMessage = .verbatim(message) }
    public init(_ message: LocalizedMessage) { localizedMessage = message }
    public var errorDescription: String? { message }
}

public extension Error {
    var localizedMessage: LocalizedMessage {
        (self as? VPNError)?.localizedMessage ?? .verbatim(localizedDescription)
    }
}
