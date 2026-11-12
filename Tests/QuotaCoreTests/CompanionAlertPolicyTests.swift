import XCTest
@testable import QuotaCore

final class CompanionAlertPolicyTests: XCTestCase {
    func testFreshInstallRequiresProviderAndCategoryOptIn() {
        XCTAssertFalse(CompanionResetAlertPolicy.allProviders(saved: nil, legacy: nil))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = UsageAlertPreferences.load(from: defaults, key: "alerts",
            resetEnabled: CompanionResetAlertPolicy.allProviders(saved: nil, legacy: nil), resetSound: .silent)
        XCTAssertFalse(preferences[.quotaReset].enabled)
        XCTAssertFalse(preferences[.vendorReset].enabled)
    }

    func testAggregateMigrationPreservesExplicitChoices() {
        XCTAssertTrue(CompanionResetAlertPolicy.allProviders(saved: nil, legacy: true))
        XCTAssertFalse(CompanionResetAlertPolicy.allProviders(saved: false, legacy: true))
        XCTAssertTrue(CompanionResetAlertPolicy.allProviders(saved: true, legacy: false))
    }

    func testCurrentOwnerReplacesPreviousOwnerSelection() {
        let selected: Set<String> = ["old-account"]
        XCTAssertEqual(CompanionResetAlertPolicy.selection(all: false, selected: selected,
            provider: "anthropic", currentOwnerIDs: ["old-account"]), true)
        XCTAssertEqual(CompanionResetAlertPolicy.selection(all: false, selected: selected,
            provider: "anthropic", currentOwnerIDs: ["current-account"]), false)
        XCTAssertNil(CompanionResetAlertPolicy.selection(all: false, selected: selected,
            provider: "anthropic", currentOwnerIDs: []))
    }

    func testUnknownOrAmbiguousProviderChoiceRemainsRetryable() {
        XCTAssertNil(CompanionResetAlertPolicy.selection(all: false, selected: ["gemini"],
            provider: "google-antigravity", currentOwnerIDs: ["gemini", "third-party"]))
        XCTAssertEqual(CompanionResetAlertPolicy.selection(all: false, selected: [],
            provider: "google-antigravity", currentOwnerIDs: ["gemini", "third-party"]), false)
        XCTAssertEqual(CompanionResetAlertPolicy.selection(all: true, selected: [],
            provider: "anthropic", currentOwnerIDs: []), true)
    }

    func testRemovalRequiresPositiveAcknowledgmentAtRequestedGeneration() throws {
        func decode(_ json: String) throws -> CompanionPushRemovalAcknowledgment {
            try JSONDecoder().decode(CompanionPushRemovalAcknowledgment.self, from: Data(json.utf8))
        }
        let removed = try decode(#"{"ok":true,"applied":true,"removed":true,"generation":12}"#)
        XCTAssertTrue(removed.confirmsRemoval(requestedGeneration: 12))
        XCTAssertFalse(removed.confirmsRemoval(requestedGeneration: 11))
        let retained = try decode(#"{"ok":true,"applied":true,"removed":false,"generation":12}"#)
        XCTAssertFalse(retained.confirmsRemoval(requestedGeneration: 12))
        let superseded = try decode(#"{"ok":true,"applied":false,"removed":false,"generation":13}"#)
        XCTAssertFalse(superseded.confirmsRemoval(requestedGeneration: 12))
        XCTAssertThrowsError(try decode(#"{"ok":true,"applied":true,"generation":12}"#))
        XCTAssertThrowsError(try decode(#"{"ok":true,"applied":true,"removed":1,"generation":12}"#))
    }
}
