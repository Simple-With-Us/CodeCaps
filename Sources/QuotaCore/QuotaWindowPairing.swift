import Foundation

/// The rule that picks a provider's two meters:  the short one and the long one.
///
/// One rule for every surface.  The Mac's Glance panel, the iOS companion and
/// the widgets all ask this question, and they used to answer it three
/// different ways, so the phone could show a quota the Mac never showed.
///
/// The rule:
///   * the short slot takes the window nearest to its cap among the windows
///     whose period is under a day, and the long slot the one nearest to its
///     cap among the rest;
///   * a slot with no candidate of its own falls back to the next window
///     nearest to its cap, so a provider that publishes one cadence still
///     fills the first slot;
///   * a window that reports no percentage never displaces one that does;
///   * the second slot never repeats the first, because a provider with one
///     weekly meter would otherwise render that meter twice and hide the
///     other cadence entirely.
///
/// The file is standalone on purpose:  the iOS app and the widget targets
/// compile QuotaCore sources by path rather than linking the module, so a
/// rule they share has to stand on its own without the rest of QuotaCore.
public enum QuotaWindowPairing {

    /// One candidate for a row's two meters.
    ///
    /// The smallest shape every surface can build from its own window type.
    public struct MeterCandidate: Equatable, Sendable {
        /// The window's identity, so the two slots never hold the same window.
        public let id: String
        /// What is left of the allowance, as a percentage.
        public let remainingPercent: Double?
        /// When the allowance comes back.
        public let resetAt: Date?
        /// Whether the window's period is under a day.
        public let isShort: Bool
        /// Whether the window is a supplementary allowance (MiniMax's video
        /// quota), a scoped pool allowance (Codex's code-review pool) or a
        /// sub-model quota (Claude's Fable, Gemini's Argon).
        ///
        /// None of those is the limit the plan is sold on, so none of them may
        /// stand in for it.  The Mac's Glance panel already hides them;  the
        /// phone used to keep one of them.  MiniMax's video allowance reached
        /// the phone as a one-day bar beside the real weekly one, because the
        /// phone picked its second meter by "the first window that is not
        /// short" and the video allowance is not short.
        public let isExcluded: Bool

        public init(
            id: String,
            remainingPercent: Double?,
            resetAt: Date?,
            isShort: Bool,
            isExcluded: Bool = false
        ) {
            self.id = id
            self.remainingPercent = remainingPercent
            self.resetAt = resetAt
            self.isShort = isShort
            self.isExcluded = isExcluded
        }
    }

    /// The two meters one provider's row draws.
    ///
    /// `isSameMeter` is an optional refinement a surface can add:  it says
    /// whether a candidate is another report of the meter the first slot
    /// already shows.  The Mac passes its copy check, because it draws two
    /// sources' readings of one allowance and must not render that meter
    /// twice;  the phone and the widget resolve their duplicates before they
    /// get here and pass nothing.
    public static func meterPair(
        _ candidates: [MeterCandidate],
        isSameMeter: ((MeterCandidate, MeterCandidate) -> Bool)? = nil
    ) -> (short: MeterCandidate?, long: MeterCandidate?) {
        let eligible = candidates.filter { !$0.isExcluded }
        guard let anchor = eligible.first else { return (nil, nil) }

        /// The window closest to its cap, preferring one that reports a
        /// percentage.  The same rule the Mac's row headline uses, so the
        /// second meter and the headline always agree on which window is
        /// closest to trouble.
        func nearestToCap(_ pool: [MeterCandidate]) -> MeterCandidate? {
            pool.filter { $0.remainingPercent != nil }
                .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
                ?? pool.first
        }
        /// A window with neither a percentage nor a reset says nothing, so it
        /// must not fill a slot with a dummy solid bar.
        func hasInformation(_ candidate: MeterCandidate) -> Bool {
            candidate.remainingPercent != nil || candidate.resetAt != nil
        }

        let shortPool = eligible.filter(\.isShort)
        let longPool = eligible.filter { !$0.isShort }
        let short = nearestToCap(shortPool) ?? nearestToCap(eligible) ?? anchor
        func distinct(_ candidate: MeterCandidate) -> Bool {
            guard candidate.id != short.id else { return false }
            guard let isSameMeter else { return true }
            return !isSameMeter(candidate, short)
        }
        let long = nearestToCap(longPool.filter(distinct).filter(hasInformation))
            ?? nearestToCap(eligible.filter(distinct).filter(hasInformation))
        return (short, long)
    }
}
