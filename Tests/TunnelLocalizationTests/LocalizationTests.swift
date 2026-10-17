import XCTest
import Observation
@testable import TunnelLocalization

final class LocalizationTests: XCTestCase {
    func testOnlyPrimarySystemLanguageIsUsed() {
        for tag in ["ru", "ru-RU", "ru_KZ", "RU-ua"] {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: [tag]), .russian)
        }
        for languages in [["en-US"], ["en-GB"], ["de", "ru"], ["fr-RU", "ru"], ["uk"], []] {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: languages), .englishUS)
        }
        XCTAssertEqual(AppLanguage.englishUS.resolved(preferredLanguages: ["ru"]), .englishUS)
        XCTAssertEqual(AppLanguage.russian.resolved(preferredLanguages: ["de"]), .russian)
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.rawValue)), ["system", "ru", "en-US"])
    }

    func testCatalogKeysAndFormatArgumentsMatch() throws {
        let ru = try catalog("ru", extension: "strings")
        let en = try catalog("en-US", extension: "strings")
        XCTAssertEqual(Set(ru.keys), Set(en.keys))
        XCTAssertGreaterThan(en.count, 350)
        let pattern = try NSRegularExpression(pattern: #"%\d+\$(?:lld|@)"#)
        for key in en.keys {
            let english = try XCTUnwrap(en[key] as? String, key)
            let russian = try XCTUnwrap(ru[key] as? String, key)
            func arguments(_ text: String) -> [String] {
                pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                    (text as NSString).substring(with: $0.range)
                }.sorted()
            }
            XCTAssertEqual(arguments(english), arguments(russian), key)
            XCTAssertFalse(english.isEmpty, key)
            XCTAssertFalse(russian.isEmpty, key)
            XCTAssertEqual(L10n.message(key).resolve(language: .englishUS).isEmpty, false, key)
        }
        let ruPlurals = try catalog("ru", extension: "stringsdict")
        let enPlurals = try catalog("en-US", extension: "stringsdict")
        XCTAssertEqual(Set(ruPlurals.keys), Set(enPlurals.keys))
        for value in ruPlurals.values {
            let count = try XCTUnwrap((value as? [String: Any])?["count"] as? [String: Any])
            for form in ["one", "few", "many", "other"] { XCTAssertNotNil(count[form]) }
        }
    }

    func testPluralFormsAndNestedMessages() {
        let expected = [1: "1 правило", 2: "2 правила", 5: "5 правил", 11: "11 правил", 21: "21 правило", 22: "22 правила", 0: "0 правил"]
        for (count, text) in expected {
            let message = L10n.message("routing.rule_count", [.init(count)])
            XCTAssertEqual(message.resolve(language: .russian), text)
            XCTAssertEqual(message.resolve(language: .englishUS), "\(count) \(count == 1 ? "rule" : "rules")")
        }
        let nested = L10n.message("routingpolicy.rule", [.init(2), .init(L10n.message("routingpolicy.choose_a_country_from_the_list"))])
        XCTAssertEqual(nested.resolve(language: .englishUS), "Rule 2: Choose a country from the list.")
        XCTAssertEqual(nested.resolve(language: .russian), "Правило 2: Выберите страну из списка.")
    }

    func testUnknownKeysUseSafeFallbackAndVerbatimIsUnchanged() {
        let message = LocalizedMessage(key: "future.message", arguments: [.init(42)], fallback: "Future message")
        XCTAssertEqual(message.resolve(language: .russian), "Future message")
        XCTAssertEqual(message.resolve(language: .englishUS), "Future message")
        XCTAssertEqual(LocalizedMessage.verbatim("engine: raw output").resolve(language: .russian), "engine: raw output")
    }

    func testMissingRussianTranslationFallsBackToUSCatalog() throws {
        let path = try XCTUnwrap(L10n.resourceBundle.path(forResource: "en-US", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(L10n.resolve("window.routing", arguments: [], language: .russian,
                                   fallback: nil, catalogs: [.englishUS: english]), "Routing")
    }

    func testCountryNamesAndStructuredRoundTrip() throws {
        let message = L10n.message("routing.country_name", [.region("DE")])
        XCTAssertEqual(message.resolve(language: .englishUS), "Germany")
        XCTAssertEqual(message.resolve(language: .russian), "Германия")
        let decoded = try JSONDecoder().decode(LocalizedMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded, message)
    }

    func testLookupsParticipateInObservation() {
        let previous = L10n.language
        defer { Localization.shared.language = previous }
        Localization.shared.language = .englishUS
        let changed = expectation(description: "Language lookup is observed")
        withObservationTracking {
            XCTAssertEqual(L10n.text("window.routing"), "Routing")
        } onChange: { changed.fulfill() }
        Localization.shared.language = .russian
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(L10n.text("window.routing"), "Маршрутизация")
    }

    private func catalog(_ language: String, extension ext: String) throws -> [String: Any] {
        let directory = try XCTUnwrap(L10n.resourceBundle.url(forResource: language, withExtension: "lproj"))
        let url = directory.appendingPathComponent("Localizable.\(ext)")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
}
