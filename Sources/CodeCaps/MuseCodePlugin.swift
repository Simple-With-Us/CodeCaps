import Foundation

/// A plugin shown in the Console's Plugins section.
///
/// The raw value is the plugin's stable identifier: it is persisted in the
/// Console page's storage key (`plugin:<id>`), so it must never be renamed
/// once shipped.
public enum CodeCapsPlugin: String, CaseIterable, Identifiable, Sendable {
    case museCode = "muse-code"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .museCode: return "Muse"
        }
    }

    public var symbol: String {
        switch self {
        case .museCode: return "puzzlepiece.extension"
        }
    }

    public static func named(_ id: String) -> CodeCapsPlugin? {
        CodeCapsPlugin(rawValue: id)
    }
}
