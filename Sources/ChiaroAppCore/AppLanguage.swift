import Foundation
import ChiaroCore

public enum ResolvedLanguage: String, Sendable, Codable, CaseIterable, Hashable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var locale: Locale {
        Locale(identifier: rawValue)
    }
}

public enum AppLanguage: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public func resolve(
        preferredLanguages: [String] = Locale.preferredLanguages,
        appleLanguagesOverride: [String]? = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
    ) -> ResolvedLanguage {
        switch self {
        case .zhHans:
            return .zhHans
        case .en:
            return .en
        case .system:
            let candidate = appleLanguagesOverride?.first ?? preferredLanguages.first ?? "en"
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.hasPrefix("zh") {
                return .zhHans
            }
            return .en
        }
    }

    public var locale: Locale {
        resolve().locale
    }
}

public extension LocalizedText {
    func localized(for language: ResolvedLanguage) -> String {
        switch language {
        case .zhHans:
            return zhHans
        case .en:
            return en
        }
    }

    func localized(for language: AppLanguage) -> String {
        localized(for: language.resolve())
    }
}
