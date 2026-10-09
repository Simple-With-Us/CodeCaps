import XCTest
@testable import QuotaCore

/// Muse Assist and Muse Code are two different subscriptions, and the app
/// showed "no report" for both while the readings sat in the handoff.
///
/// The alias table mapped `muse` to `muse-code`.  `subscription-status-cli`
/// reports Muse Assist's windows under the key `muse` ("Additional tokens",
/// "Free weekly limit"), so every one of them was rewritten to `muse-code`.
/// The expected-provider list asks for `muse-assist`, and nothing ever emitted
/// that key — so the Muse Assist row had no windows to show, and the rows that
/// did resolve carried the wrong subscription's numbers.
final class MuseProviderIdentityTests: XCTestCase {

    /// The bug, stated directly: Muse Assist's own key must not be rewritten to
    /// Muse Code's.
    func testMuseIsMuseAssistNotMuseCode() {
        XCTAssertEqual(QuotaProviders.canonicalKey(provider: "muse", providerKey: "muse", via: nil),
                       "muse-assist",
                       "'muse' is the key subscription-status-cli reports for Muse Assist")
    }

    /// The CLI spellings follow the same rule.
    func testTheMuseCliAliasesFollowTheSameRule() {
        for raw in ["muse-cli", "muse-sdk", "muse-assistant", "muse assistant"] {
            XCTAssertEqual(QuotaProviders.canonicalKey(provider: raw, providerKey: raw, via: nil),
                           "muse-assist", "'\(raw)' should resolve to Muse Assist")
        }
    }

    /// Muse Code keeps its own identity, from its own source.
    func testMuseCodeKeepsItsOwnIdentity() {
        for raw in ["muse-code", "muse code", "muse_code"] {
            XCTAssertEqual(QuotaProviders.canonicalKey(provider: raw, providerKey: raw, via: nil),
                           "muse-code", "'\(raw)' should resolve to Muse Code")
        }
    }

    /// Both rows are expected providers, so a missing reading reads as a real
    /// absence rather than an unknown platform.
    func testBothMuseProvidersAreExpected() {
        let keys = Set(QuotaProviders.expected.map(\.key))
        XCTAssertTrue(keys.contains("muse-assist"), "Muse Assist is missing from the expected list")
        XCTAssertTrue(keys.contains("muse-code"), "Muse Code is missing from the expected list")
    }

    /// The regression that would bring the bug back: a window reported under
    /// `muse` must land on the Muse Assist section, not Muse Code's.
    func testAWindowKeyedMuseLandsOnMuseAssist() {
        let canonical = QuotaProviders.canonicalKey(provider: "muse", providerKey: "muse", via: nil)
        XCTAssertNotEqual(canonical, "muse-code",
                          "Muse Assist's readings are being filed under Muse Code again")
    }
}
