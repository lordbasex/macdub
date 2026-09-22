import Foundation

/// Localized string for code paths that build strings dynamically (ternaries, AppKit menus,
/// errors). SwiftUI views with literal keys (`Text("…")`, `Button("…")`) localize on their own.
///
/// Keys are the English text. Translations live in `Sources/MacDub/Resources/<lang>.lproj/
/// Localizable.strings`; a missing key falls back to English. See README › Translations.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Formatted variant: `LF("Version %@", version)`.
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: .current, arguments: args)
}

/// Interface languages the app ships. Add a case when adding an `.lproj`.
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case spanish = "es"
    case portuguese = "pt-BR"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("System language")
        case .english: return "English"
        case .spanish: return "Español"
        case .portuguese: return "Português (Brasil)"
        }
    }

    /// Applies the override via `AppleLanguages`; takes effect on the next launch.
    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
