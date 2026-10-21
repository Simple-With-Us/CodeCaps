import XCTest
@testable import QuotaCore

/// The caption a bar prints,  starting from the bytes the backend sends.
///
/// The earlier fixture was a custom Swift struct that called the vocabulary helpers
/// directly,  so it could not catch a surface that left the qualifier out:  it never
/// went near a payload,  a decode,  or a caption.  This one starts from the payload
/// the backend sends for a Muse Assist plan,  decodes it,  derives the bars the way
/// the widget derives them,  and takes the qualifiers from the production
/// resolution.  The caption that comes out carries the qualifier,  which is what the
/// widget prints beside the bar.
///
/// The two links this cannot cover are the iOS parser and the SwiftUI render:  both
/// live in the iOS target,  which has no test target.  What holds them is the type.
/// `QuotaWindowCaption` carries its qualifier,  a caption built from a window carries
/// that window's,  and a caption row takes a caption,  so a surface that renders a
/// window's caption cannot leave the qualifier out without saying so.
final class QuotaWindowCaptionTests: XCTestCase {
    /// A Muse Assist plan as the backend sends it.
    ///
    /// The weekly limit arrives with a "weekly" token.  The extra allowance arrives
    /// with no token at all and with the label the label pipeline has already
    /// rewritten to the catch-all "Other limit" copy,  so nothing in the label says
    /// what kind of window it is:  the provider and the missing token are the whole
    /// of the signal.
    private static let museAssistPayload = """
    {
      "windows": [
        {
          "id": "muse-weekly",
          "provider": "muse-assist",
          "providerKey": "muse-assist",
          "label": "Weekly limit",
          "window": "weekly",
          "remainingPercent": 80
        },
        {
          "id": "muse-extra",
          "provider": "muse-assist",
          "providerKey": "muse-assist",
          "label": "Other limit",
          "window": null,
          "remainingPercent": 60
        }
      ]
    }
    """.data(using: .utf8)!

    /// The wire shape, as the backend sends it.
    private struct WireWindow: Decodable {
        let id: String
        let provider: String
        let providerKey: String?
        let label: String
        let window: String?
        let remainingPercent: Double?
    }

    private struct WireEnvelope: Decodable {
        let windows: [WireWindow]?
    }

    /// The bar the widget draws for a decoded window.
    ///
    /// The cadence and the extra-allowance identity come from the production
    /// vocabulary,  the way the widget's parser asks for them.
    private func bar(for window: WireWindow) -> QuotaWindowVocabulary.BarCaption {
        QuotaWindowVocabulary.BarCaption(
            cadence: QuotaWindowVocabulary.standardCadence(
                windowToken: window.window,
                label: window.label
            ),
            label: window.label,
            isExtraAllowance: QuotaWindowVocabulary.isExtraAllowance(
                providerKey: window.providerKey,
                label: window.label,
                windowToken: window.window
            )
        )
    }

    /// The caption the widget prints for a decoded window.
    private func caption(for window: WireWindow, qualifier: String) -> QuotaWindowCaption {
        QuotaWindowCaption(
            token: QuotaWindowVocabulary.popoverCaption(
                windowToken: window.window,
                label: window.label
            ),
            qualifier: qualifier,
            resetCaption: ""
        )
    }

    /// A payload's bars resolve to the owner-approved pair.
    ///
    /// The weekly limit reads "weekly" and the extra allowance reads "additional",
    /// and the extra allowance carries no token of its own,  so the qualifier is the
    /// only thing that tells the two bars apart.
    func test_a_payload_resolves_to_the_owner_approved_pair() throws {
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: Self.museAssistPayload)
        let windows = try XCTUnwrap(envelope.windows)
        XCTAssertEqual(windows.count, 2)

        let qualifiers = QuotaWindowVocabulary.barQualifiers(forBars: windows.map { bar(for: $0) })
        XCTAssertEqual(qualifiers.count, 2)
        XCTAssertEqual(qualifiers[0], QuotaWindowVocabulary.barQualifierWeekly)
        XCTAssertEqual(qualifiers[1], QuotaWindowVocabulary.barQualifierAdditional)
    }

    /// The caption a bar prints carries the qualifier the payload resolved.
    ///
    /// This is the link that was missing:  a caption row built from the window's
    /// caption prints the qualifier,  and a caption built without one does not,  so
    /// the two are different values and a surface cannot confuse them.
    func test_the_caption_carries_the_qualifier_the_payload_resolved() throws {
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: Self.museAssistPayload)
        let windows = try XCTUnwrap(envelope.windows)
        let qualifiers = QuotaWindowVocabulary.barQualifiers(forBars: windows.map { bar(for: $0) })
        let captions = zip(windows, qualifiers).map { caption(for: $0, qualifier: $1) }

        XCTAssertEqual(captions[0].qualifier, "weekly")
        XCTAssertEqual(captions[1].qualifier, "additional")
        // The two captions differ in the qualifier alone,  which is what tells the
        // two bars apart.
        XCTAssertNotEqual(captions[0].qualifier, captions[1].qualifier)
    }

    /// A lone bar prints no qualifier,  and the caption says so.
    func test_a_lone_bar_prints_no_qualifier() throws {
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: Self.museAssistPayload)
        let windows = try XCTUnwrap(envelope.windows)
        let lone = try XCTUnwrap(windows.first)
        let qualifiers = QuotaWindowVocabulary.barQualifiers(forBars: [bar(for: lone)])
        XCTAssertEqual(qualifiers, [""])
        XCTAssertEqual(caption(for: lone, qualifier: qualifiers[0]).qualifier, "")
    }

    /// A caption says whether it has anything to print.
    func test_an_empty_caption_is_empty() {
        XCTAssertTrue(QuotaWindowCaption(token: "", qualifier: "", resetCaption: "").isEmpty)
        XCTAssertFalse(
            QuotaWindowCaption(token: "7d", qualifier: "", resetCaption: "").isEmpty
        )
        XCTAssertFalse(
            QuotaWindowCaption(token: "", qualifier: "weekly", resetCaption: "").isEmpty
        )
    }

    /// The only way to have a caption without a qualifier is to ask for one.
    ///
    /// The qualifier used to be an argument with a default,  so a surface could leave
    /// it out.  Now a caption states its qualifier,  and the no-qualifier form has
    /// its own name,  so the omission is visible in the code that makes it.
    func test_a_caption_without_a_qualifier_is_asked_for_by_name() {
        let caption = QuotaWindowCaption.withoutQualifier(
            token: "7d",
            resetCaption: "Resets in 3h"
        )
        XCTAssertEqual(caption.qualifier, "")
        XCTAssertEqual(caption.token, "7d")
        XCTAssertEqual(caption.resetCaption, "Resets in 3h")
    }
}
