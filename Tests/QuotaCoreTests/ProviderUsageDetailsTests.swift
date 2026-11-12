import Foundation
import XCTest
@testable import QuotaCore

final class ProviderUsageDetailsTests: XCTestCase {
    func testCodexZeroCreditsAndResponseIdentity() {
        let details = ProviderUsageDetails.codex(
            payload: ["email": "active@example.test", "credits": ["balance": "0"]],
            tokens: ["id_token": jwt(["email": "fallback@example.test"])])
        XCTAssertEqual(details.accountEmail, "active@example.test")
        XCTAssertEqual(details.creditBalance, 0)
    }

    func testCodexIdentityFallsBackToNamespacedJWTProfile() {
        let details = ProviderUsageDetails.codex(payload: [:], tokens: [
            "access_token": jwt(["https://api.openai.com/profile": ["email": "profile@example.test"]])])
        XCTAssertEqual(details.accountEmail, "profile@example.test")
        XCTAssertNil(details.creditBalance)
    }

    func testCodexIdentityHonorsCamelCaseTokenKeys() {
        let fromAccess = ProviderUsageDetails.codex(payload: [:], tokens: [
            "accessToken": jwt(["https://api.openai.com/profile": ["email": "camel-access@example.test"]])])
        XCTAssertEqual(fromAccess.accountEmail, "camel-access@example.test")
        let fromIdentity = ProviderUsageDetails.codex(payload: [:], tokens: [
            "idToken": jwt(["email": "camel-identity@example.test"])])
        XCTAssertEqual(fromIdentity.accountEmail, "camel-identity@example.test")
    }

    func testInvalidMetadataDoesNotBecomeAReading() {
        for value: Any in [true, -1, "NaN", "inf", "unknown"] {
            XCTAssertNil(ProviderUsageDetails.codex(payload: ["credits": ["balance": value]], tokens: [:]).creditBalance)
        }
        XCTAssertNil(ProviderUsageDetails(accountEmail: "secret\n@example.test").accountEmail)
        XCTAssertNil(ProviderUsageDetails.codex(payload: [:], tokens: ["access_token": "malformed"]).accountEmail)
    }

    func testClaudeExplicitDisabledDiffersFromMissing() {
        XCTAssertEqual(ProviderUsageDetails.claude(payload: ["extra_usage": ["is_enabled": false]],
                                                 profile: ["account": ["email": "claude@example.test"]]),
                       ProviderUsageDetails(accountEmail: "claude@example.test", extraUsageEnabled: false))
        XCTAssertNil(ProviderUsageDetails.claude(payload: [:], profile: [:]).extraUsageEnabled)
    }

    func testAccountAndBalancesNeverEnterEncodedWindow() throws {
        var window = QuotaWindow(id: "test", provider: "Codex", label: "Weekly", planName: "Pro Lite", occurredAt: "2026-10-20T12:00:00Z")
        window.usageDetails = .init(accountEmail: "private@example.test", creditBalance: 42, extraUsageEnabled: true)
        let bytes = try JSONEncoder().encode(window)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(text.contains("private@example.test"))
        XCTAssertFalse(text.contains("usageDetails"))
        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: bytes)
        XCTAssertNil(decoded.usageDetails)
        XCTAssertEqual(decoded.planName, "Pro Lite")
    }

    private func jwt(_ claims: [String: Any]) -> String {
        let bytes = try! JSONSerialization.data(withJSONObject: claims)
        let body = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(body).signature"
    }
}
