import Foundation
import Observation
import TunnelLocalization

@MainActor @Observable final class LanguageSettings {
    static let shared = LanguageSettings()
    static let preferenceKey = "appLanguage"

    var selection: AppLanguage {
        didSet {
            defaults.set(selection.rawValue, forKey: Self.preferenceKey)
            refreshSystemLanguage()
        }
    }
    private(set) var effectiveLanguage: AppLanguage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferredLanguages: () -> [String]
    @ObservationIgnored private var localeObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard,
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let initial = defaults.string(forKey: Self.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        selection = initial
        effectiveLanguage = initial.resolved(preferredLanguages: preferredLanguages())
        Localization.shared.language = effectiveLanguage
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemLanguage() }
        }
    }
    func refreshSystemLanguage() {
        effectiveLanguage = selection.resolved(preferredLanguages: preferredLanguages())
        Localization.shared.language = effectiveLanguage
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
    }
    deinit { if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) } }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("TunnelDeck.appLanguageDidChange")
}
