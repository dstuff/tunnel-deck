import Foundation
import Observation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system, russian = "ru", englishUS = "en-US"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        let primary = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first?.lowercased()
        return primary == "ru" ? .russian : .englishUS
    }

    public var locale: Locale { Locale(identifier: resolved().rawValue) }
}

/// Values remain structured until presentation, including nested application errors.
public indirect enum LocalizedArgument: Codable, Equatable, Sendable {
    case string(String), integer(Int64), message(LocalizedMessage), region(String)

    public init(_ value: String) { self = .string(value) }
    public init<T: BinaryInteger>(_ value: T) { self = .integer(Int64(clamping: value)) }
    public init(_ value: LocalizedMessage) { self = .message(value) }

    fileprivate func rendered(_ language: AppLanguage) -> any CVarArg {
        switch self {
        case .string(let text): return text
        case .integer(let number): return number
        case .message(let message): return message.resolve(language: language)
        case .region(let code): return language.locale.localizedString(forRegionCode: code) ?? code
        }
    }
}

public struct LocalizedMessage: Codable, Equatable, Sendable {
    public var key: String?
    public var arguments: [LocalizedArgument]
    public var fallback: String?

    public init(key: String, arguments: [LocalizedArgument] = [], fallback: String? = nil) {
        self.key = key; self.arguments = arguments; self.fallback = fallback
    }
    public static func verbatim(_ text: String) -> Self {
        var result = Self(key: "")
        result.key = nil; result.fallback = text
        return result
    }
    public func resolve(language: AppLanguage = L10n.language) -> String {
        guard let key else { return fallback ?? "" }
        return L10n.resolve(key, arguments: arguments, language: language.resolved(), fallback: fallback)
    }
    /// Redact before retaining a message or sending it across the helper boundary.
    public func mapText(_ transform: (String) -> String) -> Self {
        var result = self
        result.fallback = fallback.map(transform)
        result.arguments = arguments.map { argument in
            switch argument {
            case .string(let value): return .string(transform(value))
            case .message(let value): return .message(value.mapText(transform))
            case .region(let value): return .region(transform(value))
            case .integer: return argument
            }
        }
        return result
    }
}

/// Observation makes lookups in SwiftUI bodies reactive; the lock also permits helper/process callbacks.
@Observable public final class Localization: @unchecked Sendable {
    public static let shared = Localization()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var selected: AppLanguage

    public init(language: AppLanguage = .system) { selected = language.resolved() }
    public var language: AppLanguage {
        get {
            access(keyPath: \.language)
            lock.lock(); defer { lock.unlock() }
            return selected
        }
        set {
            withMutation(keyPath: \.language) {
                lock.lock(); defer { lock.unlock() }
                selected = newValue.resolved()
            }
        }
    }
}

public enum L10n {
    public static var language: AppLanguage { Localization.shared.language }
    public static func text(_ key: String, _ arguments: [LocalizedArgument] = []) -> String {
        message(key, arguments).resolve()
    }
    public static func message(_ key: String, _ arguments: [LocalizedArgument] = []) -> LocalizedMessage {
        LocalizedMessage(key: key, arguments: arguments)
    }

    /// The installed bundle is checked before Bundle.module's development fallback.
    /// Helper executables live in Contents/Helpers, rather than Contents/MacOS.
    public static let resourceBundle: Bundle = {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources) }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        for directory in candidates {
            if let bundle = Bundle(url: directory.appendingPathComponent("TunnelDeck_TunnelLocalization.bundle")) { return bundle }
        }
        return Bundle.module
    }()

    private static let bundles: [AppLanguage: Bundle] = {
        var result: [AppLanguage: Bundle] = [:]
        for language in [AppLanguage.russian, .englishUS] {
            // The native SwiftPM engine canonicalizes en-US.lproj to en-us.lproj;
            // Swift Build preserves the region's case.
            for identifier in [language.rawValue, language.rawValue.lowercased()] {
                if let path = resourceBundle.path(forResource: identifier, ofType: "lproj"),
                   let bundle = Bundle(path: path) { result[language] = bundle; break }
            }
        }
        return result
    }()

    private static let argumentPattern = try! NSRegularExpression(pattern: #"%([1-9][0-9]*)\$(lld|@)"#)

    private static func accepts(_ arguments: [LocalizedArgument], format: String) -> Bool {
        if format.contains("%#@count@") {
            guard arguments.count == 1, case .integer = arguments[0] else { return false }
            return true
        }
        let matches = argumentPattern.matches(in: format, range: NSRange(format.startIndex..., in: format))
        var used = Set<Int>()
        for match in matches {
            let source = format as NSString
            guard let number = Int(source.substring(with: match.range(at: 1))),
                  number > 0, number <= arguments.count else { return false }
            used.insert(number - 1)
            let numeric = source.substring(with: match.range(at: 2)) == "lld"
            switch arguments[number - 1] {
            case .integer: if !numeric { return false }
            default: if numeric { return false }
            }
        }
        return used.count == arguments.count
    }

    fileprivate static func resolve(_ key: String, arguments: [LocalizedArgument], language: AppLanguage, fallback: String?) -> String {
        resolve(key, arguments: arguments, language: language, fallback: fallback, catalogs: bundles)
    }

    static func resolve(_ key: String, arguments: [LocalizedArgument], language: AppLanguage,
                        fallback: String?, catalogs: [AppLanguage: Bundle]) -> String {
        let missing = "\u{1}missing\u{1}"
        var renderingLanguage = language
        var format = catalogs[language]?.localizedString(forKey: key, value: missing, table: "Localizable") ?? missing
        if format == missing {
            renderingLanguage = .englishUS
            format = catalogs[.englishUS]?.localizedString(forKey: key, value: missing, table: "Localizable") ?? missing
        }
        guard format != missing else { return fallback ?? key }
        // Never pass a malformed/forward-version IPC descriptor to C varargs.
        guard accepts(arguments, format: format) else { return fallback ?? key }
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: renderingLanguage.locale, arguments: arguments.map { $0.rendered(renderingLanguage) })
    }
}
