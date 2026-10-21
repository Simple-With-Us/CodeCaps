import Foundation

/// What a window's caption says.
///
/// A caption is three parts:  the cadence token beside the bar,  the qualifier that
/// tells two bars of the same cadence apart,  and the reset line.
///
/// The qualifier is the part that used to go missing.  A caption row built without it
/// printed a bare "7d" where the row was meant to read "7d weekly",  and nothing in
/// the type said so:  the qualifier was an argument with a default,  so a surface
/// that rendered a window's caption could leave it out and the omission showed up
/// only in a review.
///
/// The type is shared so the widget and the tests use the same one.  A caption cannot
/// be built without stating its qualifier,  and a surface that renders a window's
/// caption builds it from that window,  so a qualifier cannot quietly go missing
/// again.
///
/// Plain Foundation;  no other QuotaCore type.
public struct QuotaWindowCaption: Equatable, Sendable {
    /// The cadence token:  "5h",  "7d",  "1m".
    public let token: String
    /// The word that tells two bars of the same cadence apart:  "weekly",
    /// "additional".  Empty when the bar has no sibling to tell apart from.
    public let qualifier: String
    /// The reset line:  "Resets in 12d 22m".
    public let resetCaption: String

    public init(token: String, qualifier: String, resetCaption: String) {
        self.token = token
        self.qualifier = qualifier
        self.resetCaption = resetCaption
    }

    /// The caption of a bar that has no sibling,  and so no qualifier to print.
    ///
    /// It is a separate name on purpose:  a caller that has a window uses the
    /// window's own caption,  and a caller that has no window says so here.
    public static func withoutQualifier(token: String, resetCaption: String) -> QuotaWindowCaption {
        QuotaWindowCaption(token: token, qualifier: "", resetCaption: resetCaption)
    }

    /// Whether the caption says anything at all.
    public var isEmpty: Bool {
        token.isEmpty && qualifier.isEmpty && resetCaption.isEmpty
    }
}
