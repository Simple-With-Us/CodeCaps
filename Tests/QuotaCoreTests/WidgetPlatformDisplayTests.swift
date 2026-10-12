import XCTest
@testable import QuotaCore

final class WidgetPlatformDisplayTests: XCTestCase {
    func testCursorNeverRendersAsLowercaseSlug() {
        let title = WidgetPlatformDisplay.title(
            canonicalKey: "cursor",
            manifestProviderLabel: "cursor",
            wireProvider: "cursor"
        )
        XCTAssertEqual(title, "Cursor")
        XCTAssertFalse(WidgetPlatformDisplay.isRawProviderSlug(title, canonicalKey: "cursor"))
    }

    func testNoCanonicalPlatformTitleIsRawLowercaseProviderId() {
        let slugs = [
            "cursor", "anthropic", "openai", "minimax", "xai", "grok-bot",
            "muse-assist", "muse-code", "google-antigravity", "kimi",
        ]
        for slug in slugs {
            let title = WidgetPlatformDisplay.title(
                canonicalKey: slug,
                manifestProviderLabel: slug,
                wireProvider: slug
            )
            XCTAssertFalse(
                WidgetPlatformDisplay.isRawProviderSlug(title, canonicalKey: slug),
                "widget row for \(slug) must not render the raw id \"\(title)\""
            )
        }
    }
}
