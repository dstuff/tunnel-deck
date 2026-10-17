import XCTest
import AppKit
import TunnelLocalization
import TunnelCore
@testable import TunnelDeck

@MainActor final class LanguageSettingsTests: XCTestCase {
    func testPreferencePersistsAndSystemModeUsesOnlyFirstLanguage() throws {
        let previous = L10n.language
        defer { Localization.shared.language = previous }
        let suite = "TunnelDeck-language-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferred = ["de", "ru"]
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: { preferred })
        XCTAssertEqual(settings.selection, .system)
        XCTAssertEqual(settings.effectiveLanguage, .englishUS)
        settings.selection = .russian
        XCTAssertEqual(L10n.language, .russian)
        XCTAssertEqual(defaults.string(forKey: LanguageSettings.preferenceKey), "ru")
        let restored = LanguageSettings(defaults: defaults, preferredLanguages: { preferred })
        XCTAssertEqual(restored.selection, .russian)
        restored.selection = .englishUS
        XCTAssertEqual(defaults.string(forKey: LanguageSettings.preferenceKey), "en-US")
        restored.selection = .system
        preferred = ["ru-RU", "de"]
        restored.refreshSystemLanguage()
        XCTAssertEqual(L10n.language, .russian)
        preferred = ["en-GB", "ru"]
        restored.refreshSystemLanguage()
        XCTAssertEqual(L10n.language, .englishUS)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }

    func testHistoryExportAndExistingConnectionSurviveLanguageChange() {
        let previous = L10n.language
        defer { Localization.shared.language = previous }
        Localization.shared.language = .englishUS
        let connection = ConnectionController()
        let id = UUID()
        connection.prepareDesignPreview(profile: id)
        connection.disconnect()
        connection.check(profile: VPNProfile(id: id), secrets: ProfileSecrets())
        connection.prepareDesignPreview(profile: id)
        let date = connection.connectedAt
        connection.append(L10n.message("appmodel.the_profile_was_saved_locally"))
        connection.append("Xray: original engine output")
        XCTAssertTrue(connection.exportedLog.contains("The profile was saved locally."))
        XCTAssertTrue(connection.checkResult?.contains("Interface preview") == true)
        Localization.shared.language = .russian
        XCTAssertTrue(connection.exportedLog.contains("Профиль сохранён локально."))
        XCTAssertTrue(connection.exportedLog.contains("Xray: original engine output"))
        XCTAssertTrue(connection.checkResult?.contains("Предпросмотр") == true)
        XCTAssertEqual(connection.activeProfile, id)
        XCTAssertEqual(connection.connectedAt, date)
        XCTAssertEqual(connection.state, .connected)
        XCTAssertEqual(connection.logs.count, 2)
    }

    func testMenuRetainsActionsAndShortcuts() {
        let previous = L10n.language
        defer { Localization.shared.language = previous }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        item.target = nil
        menu.addItem(item)
        Localization.shared.language = .russian
        MenuLocalization.refresh(menu: menu)
        let localized = menu.items[0]
        XCTAssertEqual(localized.title, "Скопировать")
        XCTAssertEqual(localized.action, #selector(NSText.copy(_:)))
        XCTAssertEqual(localized.keyEquivalent, "c")
        localized.title = "Copy" // AppKit's standard validation must not undo the selection.
        XCTAssertEqual(localized.title, "Скопировать")
        Localization.shared.language = .englishUS
        MenuLocalization.refresh(menu: menu)
        XCTAssertEqual(localized.title, "Copy")
    }

    func testSavedNamesAndEditorDraftAreNotTranslated() throws {
        let previous = L10n.language
        defer { Localization.shared.language = previous }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("language-profiles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(file: directory.appendingPathComponent("profiles.json"))
        Localization.shared.language = .englishUS
        let model = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(model.draft.name, "My ocserv")
        model.draft.name = "Original user name"
        model.draft.server = "unfinished server input"
        model.routing.name = "Original policy"
        XCTAssertTrue(model.save(showNotice: false))
        Localization.shared.language = .russian
        XCTAssertEqual(model.draft.name, "Original user name")
        XCTAssertEqual(model.draft.server, "unfinished server input")
        XCTAssertEqual(model.routing.name, "Original policy")
        model.add(.openConnect)
        XCTAssertEqual(model.draft.name, "Новый ocserv")
        XCTAssertEqual(model.profiles.first?.name, "Original user name")
    }
}
