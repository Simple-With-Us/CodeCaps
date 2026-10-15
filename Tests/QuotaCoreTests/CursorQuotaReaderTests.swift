import Foundation
import XCTest
@testable import QuotaCore

final class CursorQuotaReaderTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_789_000_000)

    func testReadsIncludedPlanAndTranslatesCursorAppTokenToSessionCookie() async {
        let token = Self.jwt(subject: "auth0|cursor-user-1", expiration: observedAt.addingTimeInterval(3600))
        let reader = CursorQuotaReader(
            now: { self.observedAt },
            accessToken: { token },
            fetch: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=cursor-user-1%3A%3A\(token)")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return Self.response("""
                {"billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"pro","individualUsage":{"plan":{"used":2500,"limit":10000,"remaining":7500,"totalPercentUsed":25},"onDemand":{"used":999,"limit":1000,"remaining":1}}}
                """)
            }
        )

        let result = await reader.read()
        XCTAssertNil(result.issues["cursor"])
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.providerKey, "cursor")
        XCTAssertEqual(result.windows.first?.remainingPercent, 75)
        XCTAssertEqual(result.windows.first?.absoluteRemaining, 75)
        XCTAssertEqual(result.windows.first?.absoluteLimit, 100)
        XCTAssertEqual(result.windows.first?.quotaUnit, "USD")
        XCTAssertEqual(result.windows.first?.resetAt, "2026-10-01T00:00:00Z")
        XCTAssertEqual(result.windows.first?.planName, "pro")
    }

    /// `cursorWindow` normalizes in the factory, and nothing pinned that
    /// either.  A plan down to its last few percent has to arrive as near cap
    /// rather than as an unknown the consumer would route work to.
    func testAPlanNearTheCapIsPublishedAsNearCap() async throws {
        let token = Self.jwt(subject: "auth0|cursor-user-4", expiration: observedAt.addingTimeInterval(3600))
        let reader = CursorQuotaReader(
            now: { self.observedAt },
            accessToken: { token },
            fetch: { _ in Self.response(#"{"billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"pro","individualUsage":{"plan":{"used":9500,"limit":10000,"remaining":500,"totalPercentUsed":95}}}"#) }
        )

        let result = await reader.read()
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertEqual(window.remainingPercent, 5)
        XCTAssertEqual(window.status, .nearCap)
        XCTAssertFalse(window.isExhausted)
        XCTAssertFalse(window.skip)
        XCTAssertNil(window.skipReason)
        XCTAssertFalse(window.remainingUnknown)
    }

    func testMissingLocalSessionIsActionableAndDoesNotMakeNetworkRequest() async {
        let reader = CursorQuotaReader(
            accessToken: { nil },
            fetch: { _ in
                XCTFail("missing local session must not make a request")
                return Self.response("{}", status: 500)
            }
        )
        let result = await reader.read()
        XCTAssertEqual(result.issues["cursor"], "Cursor is not signed in locally.")
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testRejectedSessionAndMalformedClaimsAreSanitized() async {
        let secret = "cursor-secret-value"
        let token = Self.jwt(subject: "auth0|cursor-user-2", expiration: observedAt.addingTimeInterval(3600))
        let rejected = CursorQuotaReader(
            now: { self.observedAt },
            accessToken: { token },
            fetch: { _ in Self.response("{\"account\":\"\(secret)\"}", status: 401) }
        )
        let rejectedResult = await rejected.read()
        XCTAssertEqual(rejectedResult.issues["cursor"], "Cursor session was rejected; sign in again in Cursor.")
        XCTAssertFalse(rejectedResult.issues.values.joined().contains(secret))

        let malformed = CursorQuotaReader(accessToken: { "not-a-jwt" }, fetch: { _ in XCTFail("invalid token must not request"); return Self.response("{}") })
        let malformedResult = await malformed.read()
        XCTAssertEqual(malformedResult.issues["cursor"], "Cursor local session is not usable; sign in again in Cursor.")
    }

    func testPlanWithoutCapRemainsUnavailableAndOnDemandIsIgnored() async {
        let token = Self.jwt(subject: "cursor-user-3", expiration: observedAt.addingTimeInterval(3600))
        let reader = CursorQuotaReader(
            now: { self.observedAt },
            accessToken: { token },
            fetch: { _ in Self.response(#"{"billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"used":100},"onDemand":{"used":1,"limit":10,"remaining":9}}}"#) }
        )
        let result = await reader.read()
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertNil(result.windows.first?.remainingPercent)
        XCTAssertNil(result.windows.first?.absoluteLimit)
        XCTAssertEqual(result.issues["cursor"], "Cursor returned no readable included quota.")
    }

    func testInjectedClockControlsExpiryAndCountFallback() async {
        let soon = Self.jwt(subject: "cursor-user-4", expiration: observedAt.addingTimeInterval(30))
        let expired = CursorQuotaReader(now: { self.observedAt }, accessToken: { soon }, fetch: { _ in
            XCTFail("expired session must not request")
            return Self.response("{}")
        })
        let expiredResult = await expired.read()
        XCTAssertEqual(expiredResult.issues["cursor"], "Cursor local session is not usable; sign in again in Cursor.")

        let valid = Self.jwt(subject: "cursor-user-5", expiration: observedAt.addingTimeInterval(3600))
        let reader = CursorQuotaReader(now: { self.observedAt }, accessToken: { valid }, fetch: { _ in
            Self.response(#"{"individualUsage":{"plan":{"used":7000,"limit":10000}}}"#)
        })
        let result = await reader.read()
        XCTAssertEqual(result.windows.first?.remainingPercent, 30)
    }

    /// The elapsed-time marker prefers the cycle's own start to a start derived
    /// from the reset, so the reader carries `billingCycleStart` through when the
    /// summary has it, and leaves it unset (the marker then derives one calendar
    /// month before the reset) when it does not.
    func testBillingCycleStartBecomesTheWindowsExplicitPeriodStart() async throws {
        let token = Self.jwt(subject: "auth0|cursor-user-5", expiration: observedAt.addingTimeInterval(3600))
        let withStart = CursorQuotaReader(now: { self.observedAt }, accessToken: { token }, fetch: { _ in
            Self.response(#"{"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"used":2500,"limit":10000}}}"#)
        })
        let withStartResult = await withStart.read()
        let window = try XCTUnwrap(withStartResult.windows.first)
        XCTAssertEqual(window.periodStart, "2026-09-01T00:00:00Z")
        XCTAssertEqual(window.window, "billing-cycle")

        let withoutStart = CursorQuotaReader(now: { self.observedAt }, accessToken: { token }, fetch: { _ in
            Self.response(#"{"billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"used":2500,"limit":10000}}}"#)
        })
        let withoutStartResult = await withoutStart.read()
        XCTAssertNil(try XCTUnwrap(withoutStartResult.windows.first).periodStart)
    }

    func testAMalformedBillingCycleStartIsDropped() async throws {
        let token = Self.jwt(subject: "auth0|cursor-user-6", expiration: observedAt.addingTimeInterval(3600))
        let reader = CursorQuotaReader(now: { self.observedAt }, accessToken: { token }, fetch: { _ in
            Self.response(#"{"billingCycleStart":"yesterday","billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"used":2500,"limit":10000}}}"#)
        })
        let result = await reader.read()
        XCTAssertNil(try XCTUnwrap(result.windows.first).periodStart)
    }

    /// X Subscription / merged Ultra accounts expose the Grok + Composer pool on
    /// DashboardService current-period usage with a ~7-day billing interval.  The
    /// legacy usage-summary monthly dollar fields can still read 100% after a
    /// mid-cycle vendor reset.
    func testWeeklyIncludedPoolUsesAutoPercentAndSevenDayWindow() async throws {
        let token = Self.jwt(subject: "auth0|cursor-user-weekly", expiration: observedAt.addingTimeInterval(3600))
        let weeklyStartMs = Int(observedAt.timeIntervalSince1970 * 1_000) - (2 * 86_400 * 1_000)
        let weeklyEndMs = weeklyStartMs + (7 * 86_400 * 1_000)
        let reader = CursorQuotaReader(
            now: { self.observedAt },
            accessToken: { token },
            fetch: { request in
                if request.url?.absoluteString.contains("GetCurrentPeriodUsage") == true {
                    return Self.response(#"{"billingCycleStart":"\#(weeklyStartMs)","billingCycleEnd":"\#(weeklyEndMs)","planUsage":{"autoPercentUsed":75,"apiPercentUsed":0,"totalPercentUsed":10}}"#)
                }
                return Self.response(#"{"billingCycleStart":"2026-08-15T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"used":0,"limit":40000,"remaining":40000,"totalPercentUsed":0}}}"#)
            }
        )
        let result = await reader.read()
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertNil(result.issues["cursor"])
        XCTAssertEqual(window.remainingPercent, 25)
        XCTAssertEqual(window.window, "weekly")
        XCTAssertEqual(window.periodStart, cursorISOString(ms: weeklyStartMs))
        XCTAssertEqual(window.resetAt, cursorISOString(ms: weeklyEndMs))
    }

    func testMidCycleVendorRestoreOnWeeklyPoolUpdatesRemainingPercent() async throws {
        let token = Self.jwt(subject: "auth0|cursor-user-restore", expiration: observedAt.addingTimeInterval(3600))
        let startMs = Int(observedAt.timeIntervalSince1970 * 1_000) - (6 * 86_400 * 1_000)
        let endMs = startMs + (7 * 86_400 * 1_000)
        let reader = CursorQuotaReader(
            now: { self.observedAt },
            accessToken: { token },
            fetch: { request in
                if request.url?.absoluteString.contains("GetCurrentPeriodUsage") == true {
                    return Self.response(#"{"billingCycleStart":"\#(startMs)","billingCycleEnd":"\#(endMs)","planUsage":{"autoPercentUsed":11}}"#)
                }
                return Self.response(#"{"billingCycleEnd":"2026-11-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"used":8900,"limit":10000,"remaining":1100,"totalPercentUsed":89}}}"#)
            }
        )
        let result = await reader.read()
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertEqual(window.remainingPercent, 89)
        XCTAssertEqual(window.window, "weekly")
    }

    func testChangedWeeklyBillingAnchorUpdatesPeriodStartAndReset() async throws {
        let token = Self.jwt(subject: "auth0|cursor-user-anchor", expiration: observedAt.addingTimeInterval(3600))
        let oldStartMs = 1_760_000_000_000
        let oldEndMs = oldStartMs + (7 * 86_400 * 1_000)
        let newStartMs = 1_761_000_000_000
        let newEndMs = newStartMs + (7 * 86_400 * 1_000)
        var call = 0
        let reader = CursorQuotaReader(
            now: { self.observedAt },
            accessToken: { token },
            fetch: { request in
                if request.url?.absoluteString.contains("GetCurrentPeriodUsage") == true {
                    call += 1
                    let start = call == 1 ? oldStartMs : newStartMs
                    let end = call == 1 ? oldEndMs : newEndMs
                    return Self.response(#"{"billingCycleStart":"\#(start)","billingCycleEnd":"\#(end)","planUsage":{"autoPercentUsed":40}}"#)
                }
                return Self.response(#"{"membershipType":"ultra","individualUsage":{"plan":{"totalPercentUsed":40}}}"#)
            }
        )
        let first = try XCTUnwrap((await reader.read()).windows.first)
        XCTAssertEqual(first.periodStart, cursorISOString(ms: oldStartMs))
        XCTAssertEqual(first.resetAt, cursorISOString(ms: oldEndMs))
        let second = try XCTUnwrap((await reader.read()).windows.first)
        XCTAssertEqual(second.periodStart, cursorISOString(ms: newStartMs))
        XCTAssertEqual(second.resetAt, cursorISOString(ms: newEndMs))
    }

    func testPeriodUsageTransportFailureStillReturnsMonthlySummary() async throws {
        let token = Self.jwt(subject: "auth0|cursor-user-fallback", expiration: observedAt.addingTimeInterval(3600))
        let reader = CursorQuotaReader(
            now: { self.observedAt },
            accessToken: { token },
            fetch: { request in
                if request.url?.absoluteString.contains("GetCurrentPeriodUsage") == true {
                    throw URLError(.timedOut)
                }
                if request.url?.absoluteString.contains("get-current-period-usage") == true {
                    throw URLError(.networkConnectionLost)
                }
                return Self.response(#"{"billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"pro","individualUsage":{"plan":{"used":2500,"limit":10000,"remaining":7500,"totalPercentUsed":25}}}"#)
            }
        )
        let result = await reader.read()
        XCTAssertNil(result.issues["cursor"])
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertEqual(window.remainingPercent, 75)
        XCTAssertEqual(window.resetAt, "2026-10-01T00:00:00Z")
        XCTAssertEqual(window.window, "billing-cycle")
    }

    func testOversizedTokenFailsClosedBeforeRequest() async {
        let oversized = String(repeating: "a", count: 65_537)
        let reader = CursorQuotaReader(accessToken: { oversized }, fetch: { _ in
            XCTFail("oversized session must not request")
            return Self.response("{}")
        })
        let result = await reader.read()
        XCTAssertEqual(result.issues["cursor"], "Cursor local session is not usable; sign in again in Cursor.")
    }

    private static func jwt(subject: String, expiration: Date) -> String {
        let header = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let body = try! JSONSerialization.data(withJSONObject: ["sub": subject, "exp": expiration.timeIntervalSince1970])
        let payload = body.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).signature"
    }

    private static func response(_ text: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/usage-summary")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(text.utf8), response)
    }

    private static func cursorISOString(ms: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
    }
}
