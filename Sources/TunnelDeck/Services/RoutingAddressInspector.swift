import Foundation
import TunnelCore

enum RoutingAddressInspector {
    struct Result: Sendable {
        let action: RoutingAction
        let explanation: String
        let addresses: [String]
    }
    @MainActor static func check(_ input: String, policy: RoutingPolicy, runtime: RuntimePaths,
                                 session: RoutingRuntimeInfo?) async throws -> Result {
        let policy = try policy.validated()
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let literal = IPNetwork.address(value) != nil
        let domain = literal ? nil : try RoutingMatch.domain(value)
        let country = try CountryDatabase(url: runtime.geoIP.appendingPathComponent("countries.bin"))
        var addresses: [String] = literal ? [value] : []
        if let domain {
            let withoutDNS = try policy.decision(domain: domain, addresses: [], country: country.country)
            let before = withoutDNS.ruleIndex ?? policy.rules.count
            let needsIP = policy.rules.prefix(before).contains { $0.enabled && [.country, .ipCIDR].contains($0.match.type) }
            if withoutDNS.ruleIndex == nil || needsIP {
                for family in ["A", "AAAA"] {
                    var args = ["+short", "+time=2", "+tries=1"]
                    if let session { args += ["+tcp", "-p", String(session.dnsPort), "@127.0.0.1"] }
                    args += [domain, family]
                    let result = try await ProcessRunner().run("/usr/bin/dig", args)
                    addresses += result.stdout.components(separatedBy: .whitespacesAndNewlines).filter { IPNetwork.address($0) != nil }
                }
                guard !addresses.isEmpty else { throw VPNError("Не удалось получить IP сайта. Результат правил по сетям и странам не определён.") }
            }
        }
        try Task.checkCancellation()
        let result = try policy.decision(domain: domain, addresses: addresses, country: country.country)
        let explanation: String
        if let index = result.ruleIndex {
            let rule = policy.rules[index]
            let detail = result.matchedIP.map { " (IP \($0))" } ?? ""
            explanation = "Совпало правило № \(index + 1): \(rule.match.displayValue)\(detail)."
        } else { explanation = "Ни одно правило не подошло. Используется действие для остального интернета." }
        return Result(action: result.action, explanation: explanation, addresses: Array(Set(addresses)).sorted())
    }
}
