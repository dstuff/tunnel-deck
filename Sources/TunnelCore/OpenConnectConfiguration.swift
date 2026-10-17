import TunnelLocalization
import Foundation

public struct VPNEndpoint: Sendable {
    public let url: String
    public let baseURL: String
    public let secret: String
    public let host: String

    public init(server: String, camouflage: String = "") throws {
        var input = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.contains("://") { input = "https://" + input }
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: input), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil,
              components.password == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw VPNError(L10n.message("openconnectconfiguration.enter_an_https_server_address_without_a_username_or"))
        }
        let parts = input.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let originalQuery = parts.count == 2 ? String(parts[1]) : ""
        let secret = camouflage.isEmpty ? originalQuery : camouflage
        guard originalQuery.isEmpty || camouflage.isEmpty || originalQuery == camouflage else {
            throw VPNError(L10n.message("openconnectconfiguration.the_secret_in_the_address_differs_from_the_camouflage"))
        }
        let base = String(parts[0])
        let full = base + (secret.isEmpty ? "" : "?" + secret)
        guard let check = URLComponents(string: full), check.url != nil,
              check.percentEncodedQuery == (secret.isEmpty ? nil : secret) else {
            throw VPNError(L10n.message("openconnectconfiguration.the_url_secret_contains_invalid_characters_use_the_exact"))
        }
        self.url = full; self.baseURL = base; self.secret = secret; self.host = host
    }
}

public enum OpenConnectConfiguration {
    public static func make(profile: VPNProfile, secrets: ProfileSecrets) throws -> String {
        let endpoint = try VPNEndpoint(server: profile.server, camouflage: secrets.camouflage)
        for value in [profile.username, profile.authGroup, profile.certificatePin] {
            guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
                throw VPNError(L10n.message("openconnectconfiguration.connection_fields_must_not_contain_line_breaks"))
            }
        }
        if !profile.certificatePin.isEmpty,
           !profile.certificatePin.hasPrefix("pin-sha256:"),
           !profile.certificatePin.hasPrefix("sha256:") {
            throw VPNError(L10n.message("openconnectconfiguration.the_certificate_fingerprint_must_start_with_pin_sha256_or"))
        }
        var lines = ["protocol=anyconnect", "server=\(endpoint.url)", "non-inter", "no-proxy"]
        if !profile.username.isEmpty { lines.append("user=\(profile.username)") }
        if !profile.authGroup.isEmpty { lines.append("authgroup=\(profile.authGroup)") }
        if !profile.certificatePin.isEmpty { lines.append("servercert=\(profile.certificatePin)") }
        if profile.disableDTLS { lines.append("no-dtls") }
        return lines.joined(separator: "\n") + "\n"
    }
}
