import Foundation

/// Transcription language choices. A session stores either a locale identifier (`fr-FR`) or
/// `automatic`, which lets the pipeline pick among the installed languages.
public enum SpeechLanguage {
    public static let automatic = "auto"
    public static let defaultLocale = "fr-FR"
    /// Preferred region when a language is installed in several regional variants.
    static let canonicalRegions = ["en": "US", "fr": "FR", "de": "DE", "es": "ES", "it": "IT", "pt": "BR", "zh": "CN", "ja": "JP", "ko": "KR", "yue": "CN"]

    /// `fr_FR`, `fr-FR` and `fr` all give `fr`.
    public static func languageCode(of identifier: String) -> String {
        String(identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(identifier)).lowercased()
    }
    /// BCP 47 form (`fr-FR`), the one stored in sessions and exports.
    public static func normalized(_ identifier: String) -> String { identifier.replacingOccurrences(of: "_", with: "-") }

    /// Keeps one locale per language: the user's region when available, then the canonical region,
    /// then the first in sorted order. Order follows first appearance of each language.
    public static func oneLocalePerLanguage(_ identifiers: [String], preferredRegion: String? = Locale.current.region?.identifier) -> [String] {
        var order: [String] = [], byLanguage: [String: [String]] = [:]
        for identifier in identifiers.map(normalized) {
            let language = languageCode(of: identifier)
            if byLanguage[language] == nil { order.append(language) }
            byLanguage[language, default: []].append(identifier)
        }
        return order.compactMap { language in
            let variants = byLanguage[language, default: []].sorted()
            func region(_ value: String) -> String? { value.split(separator: "-").dropFirst().first.map(String.init)?.uppercased() }
            if let preferredRegion, let match = variants.first(where: { region($0) == preferredRegion.uppercased() }) { return match }
            if let canonical = canonicalRegions[language], let match = variants.first(where: { region($0) == canonical }) { return match }
            return variants.first
        }
    }
    /// Fallback for automatic detection: the first preferred system language that is installed,
    /// otherwise French when installed, otherwise the first installed language.
    public static func fallback(installed: [String], preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let candidates = oneLocalePerLanguage(installed)
        for preferred in preferredLanguages {
            if let match = candidates.first(where: { languageCode(of: $0) == languageCode(of: preferred) }) { return match }
        }
        return candidates.first(where: { languageCode(of: $0) == "fr" }) ?? candidates.first ?? defaultLocale
    }
    /// Name of the language in the interface language, capitalized (`Français`, `English`).
    public static func displayName(_ identifier: String, in locale: Locale = .current) -> String {
        let name = locale.localizedString(forLanguageCode: languageCode(of: identifier)) ?? identifier
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
