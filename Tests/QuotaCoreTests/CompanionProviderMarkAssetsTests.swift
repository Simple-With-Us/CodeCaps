import XCTest
@testable import QuotaCore

/// CC-224: xAI rows must wear the xAI mark and title, not the Grok CLI artwork.
final class CompanionProviderMarkAssetsTests: XCTestCase {
    func testCanonicalKeySeparatesXaiFromGrok() {
        XCTAssertEqual(CompanionProviderRouting.canonicalKey(provider: "xAI", providerKey: "xai", via: nil), "xai")
        XCTAssertEqual(CompanionProviderRouting.canonicalKey(provider: "Grok", providerKey: "grok", via: nil), "grok")
        XCTAssertEqual(CompanionProviderRouting.canonicalKey(provider: "Grok", providerKey: "grok-cli", via: nil), "grok")
        XCTAssertEqual(CompanionProviderRouting.canonicalKey(provider: "Grok Bot", providerKey: "grok-bot", via: "cursor"), "grok-bot")
        XCTAssertEqual(CompanionProviderRouting.canonicalKey(provider: "xAI", providerKey: "grok-build", via: nil), "xai")
    }

    func testCatalogAssetNameDistinguishesXaiGrokAndGrokBot() {
        XCTAssertEqual(CompanionProviderMarkAssets.catalogAssetName(providerKey: "xai"), "provider-xai")
        XCTAssertEqual(CompanionProviderMarkAssets.catalogAssetName(providerKey: "x-ai"), "provider-xai")
        XCTAssertEqual(CompanionProviderMarkAssets.catalogAssetName(providerKey: "grok-build"), "provider-xai")
        XCTAssertEqual(CompanionProviderMarkAssets.catalogAssetName(providerKey: "grok"), "provider-grok")
        XCTAssertEqual(CompanionProviderMarkAssets.catalogAssetName(providerKey: "grok-cli"), "provider-grok")
        XCTAssertEqual(CompanionProviderMarkAssets.catalogAssetName(providerKey: "grok-bot"), "provider-grok-bot")
    }

    func testXaiRowTitleMatchesMacLabel() {
        let title = WidgetPlatformDisplay.title(canonicalKey: "xai", wireProvider: "xai")
        XCTAssertEqual(title, "xAI")
        XCTAssertEqual(WidgetPlatformDisplay.title(canonicalKey: "grok", wireProvider: "grok"), "Grok")
    }
}
