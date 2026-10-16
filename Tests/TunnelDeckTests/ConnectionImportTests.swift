import XCTest
import TunnelCore
@testable import TunnelDeck

final class ConnectionImportTests: XCTestCase {
    func testOpenConnectImportSeparatesSecretWithoutChangingQuery() throws {
        let imported = try ConnectionImport("https://vpn.example:443/login?synthetic%2Fsecret+with=parameters")
        XCTAssertEqual(imported.kind, .openConnect)
        XCTAssertEqual(imported.server, "https://vpn.example:443/login")
        XCTAssertEqual(imported.secrets.camouflage, "synthetic%2Fsecret+with=parameters")
        XCTAssertEqual(imported.suggestedName, "vpn.example")
    }

    func testLinkAndJSONKeepOriginalConfiguration() throws {
        let link = "vless://synthetic-id@vpn.example:443?security=tls#Work"
        let imported = try ConnectionImport(link)
        XCTAssertEqual(imported.kind, .xray)
        XCTAssertEqual(imported.suggestedName, "Work")
        XCTAssertEqual(imported.secrets.configuration, link)
        let json = "{\"outbounds\":[{\"protocol\":\"freedom\"}]}"
        XCTAssertEqual(try ConnectionImport(json).secrets.configuration, json)
    }

    func testInvalidInputsAreRejectedLocally() {
        for input in ["", "{broken-json", "[Interface]\nPrivateKey = invalid", "vless://incomplete", "http://vpn.example", String(repeating: "x", count: 256_000)] {
            XCTAssertThrowsError(try ConnectionImport(input))
        }
    }

    func testAmneziaFileWithLeadingCommentsIsRecognizedWithoutRewriting() throws {
        let key = Data(repeating: 0, count: 32).base64EncodedString()
        let text = """
        # Synthetic test configuration
        [Interface]
        PrivateKey = \(key)
        Address = 10.0.0.2/32
        [Peer]
        PublicKey = \(key)
        Endpoint = vpn.example:51820
        AllowedIPs = 0.0.0.0/0
        """
        let imported = try ConnectionImport(text)
        XCTAssertEqual(imported.kind, .amneziaWG)
        XCTAssertEqual(imported.secrets.configuration, text)
    }
}
