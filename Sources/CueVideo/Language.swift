import Foundation

/// The language of the help texts: what a button does, what a setting is for, why something failed.
/// Names of programs and technical terms (NDI, ATEM, vMix, UYVY…) and the labels on controls stay in
/// English whatever is chosen.
enum Language: String, CaseIterable, Identifiable {
    case en, es
    var id: String { rawValue }
    var name: String { self == .es ? "Español" : "English" }
}

enum Lang {
    /// The language picked in Setup, or nil to follow the Mac's (Spanish when it prefers Spanish).
    /// Set from the setup file; everything reads `current`.
    nonisolated(unsafe) static var chosen: Language?

    static func system(_ preferred: [String] = Locale.preferredLanguages) -> Language {
        preferred.first?.lowercased().hasPrefix("es") == true ? .es : .en
    }

    static var current: Language {
        if let chosen { return chosen }
        // Tests read the English texts whatever the Mac running them prefers.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .en }
        return system()
    }
}

/// A help text in the language in use. The English comes first and is the fallback; give the Spanish
/// next to it, so the two are read and kept together. Text with values in it takes them in both:
///
///     tr("Remove \(name)", es: "Quitar \(name)")
func tr(_ en: String, es: @autoclosure () -> String) -> String {
    Lang.current == .es ? es() : en
}
