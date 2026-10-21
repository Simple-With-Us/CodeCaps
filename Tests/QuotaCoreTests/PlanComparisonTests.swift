import XCTest
@testable import QuotaCore

final class PlanComparisonTests: XCTestCase {
    func testEquivalentProviderPrefixesAndFormatting() {
        for (detected, entered, provider) in [("Max 20x", "Claude Max 20×", "anthropic"),
                                               ("prolite", "ChatGPT Pro Lite", "openai"),
                                               ("Pro+", "GitHub Copilot Pro +", "github-copilot")] {
            XCTAssertFalse(PlanComparison.disagrees(detected: detected, entered: entered, providerKey: provider))
        }
    }

    func testRawCopilotApiTokensAliasToUserFacingTiers() {
        // The API reports raw tokens; users type display names (Sentry on #277).
        XCTAssertFalse(PlanComparison.disagrees(detected: "individual_pro", entered: "Copilot Pro", providerKey: "github-copilot"))
        XCTAssertFalse(PlanComparison.disagrees(detected: "individual_pro", entered: "Pro", providerKey: "github-copilot"))
        XCTAssertFalse(PlanComparison.disagrees(detected: "individual_pro_plus", entered: "GitHub Copilot Pro+", providerKey: "github-copilot"))
        XCTAssertFalse(PlanComparison.disagrees(detected: "free", entered: "Copilot Free", providerKey: "github-copilot"))
        XCTAssertTrue(PlanComparison.disagrees(detected: "individual_pro", entered: "Copilot Business", providerKey: "github-copilot"))
    }

    func testRealTierDifferencesStayDifferent() {
        XCTAssertTrue(PlanComparison.disagrees(detected: "Max 20x", entered: "Max 5x", providerKey: "anthropic"))
        XCTAssertTrue(PlanComparison.disagrees(detected: "Pro+", entered: "Pro", providerKey: "github-copilot"))
        XCTAssertTrue(PlanComparison.disagrees(detected: "prolite", entered: "Pro", providerKey: "openai"))
    }

    func testMissingOrUnknownPlansNeverProduceMismatch() {
        for value: String? in [nil, "", "  ", "Unknown", "Unavailable", "Not reported"] {
            XCTAssertFalse(PlanComparison.disagrees(detected: value, entered: "Pro", providerKey: "openai"))
            XCTAssertFalse(PlanComparison.disagrees(detected: "Pro", entered: value, providerKey: "openai"))
        }
        XCTAssertFalse(PlanComparison.disagrees(detected: "Max 20x", entered: "Max", providerKey: "anthropic"))
    }

    func testMetadataTextBoundsRemainValidAcrossUnicodeConsumers() {
        let custom = PlatformCustomInfo(customSubtitle: String(repeating: "🙂", count: 1024))
        let metadata = PlanMetadata(detectedPlanName: nil, customInfo: custom, providerKey: "openai")
        XCTAssertLessThanOrEqual(metadata.userSubtitle?.utf8.count ?? 0, 1024)
        XCTAssertFalse(metadata.userSubtitle?.contains("�") == true)
    }

    func testMetadataKeepsEnteredValuesSeparateAndNeverInfersPlanFromCost() throws {
        let custom = PlatformCustomInfo(customSubtitle: "Work account", planName: "Max 5x", costUsd: "$100/mo",
                                        renewalDateText: "November 1", showCostAndRenewal: false)
        let meta = PlanMetadata(detectedPlanName: "Max 20x", customInfo: custom, providerKey: "anthropic")
        XCTAssertTrue(meta.hasMismatch)
        XCTAssertEqual(meta.detectedPlanName, "Max 20x")
        XCTAssertEqual(meta.userPlanName, "Max 5x")
        XCTAssertEqual(meta.userCostUsd, "$100/mo")
        XCTAssertEqual(meta.showCostAndRenewal, false)
        XCTAssertEqual(try JSONDecoder().decode(PlanMetadata.self, from: JSONEncoder().encode(meta)), meta)
        let absent = PlanMetadata(detectedPlanName: nil, customInfo: custom, providerKey: "anthropic")
        XCTAssertFalse(absent.hasMismatch)
        XCTAssertNil(absent.detectedPlanName)
    }
}
