import Foundation
import XCTest
@testable import QuotaCore

final class QuotaCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        StubURLProtocol.seenURLs = []
        StubURLProtocol.handler = nil
    }

    private func window(
        provider: String = "claude-code",
        providerKey: String? = nil,
        via: String? = nil,
        percentage: Double? = 50,
        occurred: String = "2023-11-14T22:00:00Z",
        reset: String? = nil
    ) -> QuotaWindow {
        QuotaWindow(
            id: UUID().uuidString,
            provider: provider,
            providerKey: providerKey,
            via: via,
            label: provider,
            remainingPercent: percentage,
            remainingUnknown: percentage == nil,
            resetAt: reset,
            occurredAt: occurred
        )
    }

    func testWireResponseDecodesOriginalAndAdditiveFields() throws {
        let data = #"{"generatedAt":"2023-11-14T22:10:00Z","windows":[{"id":"a","provider":"claude-code","sourceApp":null,"modelId":null,"modelType":null,"label":"Claude","remainingPercent":12.5,"remainingUnknown":false,"isExhausted":false,"resetAt":null,"window":"5h","status":"near_cap","skip":false,"skipReason":null,"occurredAt":"2023-11-14T22:00:00Z","source":"local","providerKey":"anthropic","providerLabel":"Claude","via":null}],"skipModelTypes":[]}"#.data(using: .utf8)!

        let response = try JSONDecoder().decode(QuotaResponse.self, from: data)
        XCTAssertEqual(response.windows.first?.providerKey, "anthropic")
        XCTAssertEqual(response.windows.first?.remainingPercent, 12.5)
        XCTAssertTrue(response.providerGroups.isEmpty)
        XCTAssertEqual(response.platformSections(now: now).first?.providerKey, "anthropic")
    }

    func testProviderGroupDecodesAdditiveFields() throws {
        // Phase 2 backend manifest carries the new additive fields per group.
        let data = #"{"provider":"anthropic","providerLabel":"Claude Code","via":null,"expected":true,"windows":[],"sortOrder":0,"iconHint":"claude","terms":{"defaultWindowLabel":"5h"}}"#.data(using: .utf8)!
        let group = try JSONDecoder().decode(QuotaProviderGroup.self, from: data)
        XCTAssertEqual(group.provider, "anthropic")
        XCTAssertEqual(group.providerLabel, "Claude Code")
        XCTAssertEqual(group.sortOrder, 0)
        XCTAssertEqual(group.iconHint, "claude")
        XCTAssertEqual(group.terms?.defaultWindowLabel, "5h")
    }

    func testProviderGroupDecodesWithoutAdditiveFields() throws {
        // Legacy payloads without sortOrder/iconHint/terms must still decode.
        let data = #"{"provider":"openai","providerLabel":"Codex","via":null,"expected":true,"windows":[]}"#.data(using: .utf8)!
        let group = try JSONDecoder().decode(QuotaProviderGroup.self, from: data)
        XCTAssertNil(group.sortOrder)
        XCTAssertNil(group.iconHint)
        XCTAssertNil(group.terms)
    }

    func testPlatformSectionsHonoursServerSortOrderAndLabels() {
        // The server returns providerGroups in a custom order with a renamed
        // label; the section order and labels must reflect the server view.
        let groups: [QuotaProviderGroup] = [
            QuotaProviderGroup(provider: "minimax", providerLabel: "Hailuo Video", via: nil, expected: false, windows: [], sortOrder: 0, iconHint: "minimax", terms: QuotaProviderTerms(defaultWindowLabel: "5h")),
            QuotaProviderGroup(provider: "anthropic", providerLabel: "Claude Code", via: nil, expected: true, windows: [], sortOrder: 1, iconHint: "claude", terms: QuotaProviderTerms(defaultWindowLabel: "5h")),
            QuotaProviderGroup(provider: "openai", providerLabel: "ChatGPT Plus", via: nil, expected: true, windows: [], sortOrder: 2, iconHint: "openai", terms: nil),
        ]
        let response = QuotaResponse(generatedAt: "", windows: [], providerGroups: groups)
        let sections = response.platformSections(now: now)
        XCTAssertEqual(sections.map(\.providerKey), ["minimax", "anthropic", "openai"])
        XCTAssertEqual(sections.map(\.providerLabel), ["Hailuo Video", "Claude Code", "ChatGPT Plus"])
        XCTAssertEqual(sections.first?.iconHint, "minimax")
        // `defaultWindowLabel` is carried on the group; the section carries
        // the icon hint.  The widget reads the label off the group.
        XCTAssertEqual(groups[1].terms?.defaultWindowLabel, "5h")
    }

    func testPlatformSectionsFallBackToHardcodedListWhenProviderGroupsEmpty() {
        // Offline / pre-manifest path: no providerGroups, fall back to the
        // bundled list.  The list's order and labels must match.
        let response = QuotaResponse(generatedAt: "", windows: [])
        let sections = response.platformSections(now: now)
        XCTAssertEqual(Array(sections.prefix(9)).map(\.providerKey), [
            "anthropic", "openai", "google-antigravity", "cursor", "github-copilot", "xai", "grok", "grok-bot", "minimax",
        ])
        XCTAssertEqual(sections.first?.providerLabel, "Claude")
        XCTAssertNil(sections.first?.iconHint)
    }

    func testPlatformSectionsServerLabelWinsOnRename() {
        // Server renames "Codex" to "ChatGPT Plus"; the bundled label must
        // not appear, and the server-supplied label must win.
        let groups = [
            QuotaProviderGroup(provider: "openai", providerLabel: "ChatGPT Plus", via: nil, expected: true, windows: [], sortOrder: 0, iconHint: "openai", terms: nil)
        ]
        let response = QuotaResponse(generatedAt: "", windows: [], providerGroups: groups)
        let sections = response.platformSections(now: now)
        let openai = sections.first { $0.providerKey == "openai" }
        XCTAssertNotNil(openai)
        XCTAssertEqual(openai?.providerLabel, "ChatGPT Plus")
        XCTAssertEqual(openai?.iconHint, "openai")
    }

    func testPlatformSectionsHiddenProvidersStillFilteredWithManifest() {
        // The `hidden` set drops retired keys even when the manifest names them.
        let groups = [
            QuotaProviderGroup(provider: "kimi", providerLabel: "Kimi", via: nil, expected: true, windows: [], sortOrder: 0, iconHint: nil, terms: nil)
        ]
        let response = QuotaResponse(generatedAt: "", windows: [], providerGroups: groups)
        let sections = response.platformSections(now: now)
        XCTAssertFalse(sections.contains { $0.providerKey == "kimi" })
    }

    func testPlatformSectionsFutureKeyStillAppearsAfterManifest() {
        // A window whose canonical key is not in the manifest must still get
        // a section.  The server label wins when present, the hardcoded one
        // otherwise.
        let groups = [
            QuotaProviderGroup(provider: "anthropic", providerLabel: "Claude Code", via: nil, expected: true, windows: [], sortOrder: 0, iconHint: nil, terms: nil)
        ]
        let future = window(provider: "new-provider", occurred: "2023-11-14T22:05:00Z")
        let response = QuotaResponse(generatedAt: "2023-11-14T22:10:00Z", windows: [future], providerGroups: groups)
        let sections = response.platformSections(now: now)
        XCTAssertEqual(sections.first?.providerKey, "anthropic")
        XCTAssertTrue(sections.contains { $0.providerKey == "new-provider" })
    }

    func testAliasesAndAntigravityIdentity() {
        let antigravity = window(provider: "anthropic", via: "antigravity")
        let claude = window(provider: "claude-code")
        XCTAssertEqual(antigravity.canonicalProviderKey, "google-antigravity")
        XCTAssertEqual(claude.canonicalProviderKey, "anthropic")

        let sections = QuotaResponse(generatedAt: "now", windows: [antigravity, claude]).platformSections(now: now)
        XCTAssertEqual(sections.first(where: { $0.providerKey == "google-antigravity" })?.windows.count, 4)
        XCTAssertEqual(sections.first(where: { $0.providerKey == "anthropic" })?.windows.count, 1)
    }

    func testUnknownAndNonFinitePercentagesStayUnknown() {
        let omitted = window(percentage: nil)
        let nan = window(percentage: .nan)
        let omittedSnapshot = QuotaWindowSnapshot(window: omitted, now: now)
        let nanSnapshot = QuotaWindowSnapshot(window: nan, now: now)
        XCTAssertNil(omittedSnapshot.remainingPercent)
        XCTAssertNil(nanSnapshot.remainingPercent)
        XCTAssertEqual(omittedSnapshot.status, .unknown)
        XCTAssertEqual(nanSnapshot.status, .unknown)
    }

    func testUnusedPlatformsStayHiddenEvenWhenServerReportsThem() {
        let hidden = ["kimi", "windsurf", "deepseek", "gemini-cli"]
        let windows = hidden.map { key in
            QuotaWindow(id: key, provider: key, label: "Quota", remainingPercent: 30, occurredAt: "2023-11-14T22:13:20Z")
        }
        let response = QuotaResponse(generatedAt: "", windows: windows)
        XCTAssertTrue(Set(response.platformSections(now: now).map(\.providerKey)).isDisjoint(with: hidden))
    }

    func testGeminiCLIRemainsHiddenWhenReported() {
        let gemini = QuotaWindow(id: "gemini", provider: "gemini-cli", providerLabel: "Gemini CLI", label: "Gemini Pro", remainingPercent: 42, occurredAt: "2023-11-14T22:13:20Z")
        let sections = QuotaResponse(generatedAt: "", windows: [gemini]).platformSections(now: now)
        XCTAssertFalse(sections.contains { $0.providerKey == "gemini-cli" })
    }

    func testVideoClassificationDoesNotDemoteCodingOrOtherProviders() {
        let video = QuotaWindow(id: "video", provider: "minimax", modelId: "video", label: "1d", occurredAt: "")
        let coding = QuotaWindow(id: "coding", provider: "minimax", modelId: "MiniMax-M2", label: "5h", occurredAt: "")
        let other = QuotaWindow(id: "other", provider: "xai", label: "Video", occurredAt: "")
        XCTAssertTrue(video.isSupplementaryVideoQuota)
        XCTAssertFalse(coding.isSupplementaryVideoQuota)
        XCTAssertFalse(other.isSupplementaryVideoQuota)
    }

    func testPercentagesAreClampedWithoutInventingCaps() {
        XCTAssertEqual(QuotaWindowSnapshot(window: window(percentage: 130), now: now).remainingPercent, 100)
        XCTAssertEqual(QuotaWindowSnapshot(window: window(percentage: -5), now: now).remainingPercent, 0)
        XCTAssertNil(QuotaWindowSnapshot(window: window(percentage: nil), now: now).remainingPercent)
    }

    func testMissingInvalidAndOldObservationAreStale() {
        let missing = window(occurred: "")
        let invalid = window(occurred: "yesterday-ish")
        let old = window(occurred: "2023-11-14T21:00:00Z")
        XCTAssertEqual(QuotaWindowSnapshot(window: missing, now: now).freshness, .stale)
        XCTAssertEqual(QuotaWindowSnapshot(window: invalid, now: now).freshness, .stale)
        XCTAssertEqual(QuotaWindowSnapshot(window: old, now: now).freshness, .stale)
    }

    func testPassedResetAwaitsRefresh() {
        let value = window(reset: "2023-11-14T22:10:00Z")
        let snapshot = QuotaWindowSnapshot(window: value, now: now)
        XCTAssertEqual(snapshot.freshness, .awaitingRefresh)
        XCTAssertTrue(snapshot.isAwaitingRefresh)
    }

    func testExpectedSectionsAndFutureProviders() {
        let future = window(provider: "new-provider", occurred: "2023-11-14T22:05:00Z")
        let response = QuotaResponse(generatedAt: "2023-11-14T22:10:00Z", windows: [future])
        let sections = response.platformSections(now: now)
        XCTAssertEqual(Array(sections.prefix(11)).map(\.providerKey), [
            "anthropic", "openai", "google-antigravity", "cursor", "github-copilot", "xai", "grok", "grok-bot", "minimax", "muse-assist", "muse-code",
        ])
        XCTAssertTrue(sections.prefix(11).allSatisfy(\.isMissing))
        XCTAssertEqual(sections.last?.providerKey, "new-provider")
    }

    func testDeepSeekServerWindowIsDroppedNotShownAsUnknown() {
        // deepseek was retired as a quota provider; a server payload that still
        // tags a window deepseek must not resurrect it as a "future" section.
        let deepseekWindow = window(provider: "deepseek", occurred: "2023-11-14T22:05:00Z")
        let response = QuotaResponse(generatedAt: "2023-11-14T22:10:00Z", windows: [deepseekWindow])
        let sections = response.platformSections(now: now)
        XCTAssertFalse(sections.contains { $0.providerKey == "deepseek" })
        XCTAssertEqual(sections.count, expectedQuotaProviderKeys.count)
    }

    func testFreshWindowsSortByLowRemainingAndUnknownLast() {
        let high = window(provider: "cursor", percentage: 80, occurred: "2023-11-14T22:05:00Z")
        let low = window(provider: "cursor", percentage: 5, occurred: "2023-11-14T22:05:00Z")
        let unknown = window(provider: "cursor", percentage: nil, occurred: "2023-11-14T22:05:00Z")
        let section = QuotaResponse(generatedAt: "now", windows: [high, unknown, low])
            .platformSections(now: now).first(where: { $0.providerKey == "cursor" })!
        XCTAssertEqual(section.windows.map(\.remainingPercent), [5, 80, nil])
    }

    /// Owner 2026-10-23: the xAI row showed two 7-day windows at 0% with a
    /// "due" caption while Grok, Cursor and Grok Bot showed the same weekly
    /// allowance at 91% with a reset on 2026-10-29.  This Mac reads no xAI
    /// quota locally, so the fleet fallback filled the xAI row with copies of
    /// a period that ended days earlier, and the section printed them as live
    /// readings.
    ///
    /// A copy of a period that ended is not a reading, so it is dropped where
    /// the fleet copies enter, before the section is built.  The rule belongs
    /// there and nowhere else:  a section builder that drops expired windows
    /// also drops this Mac's own expired reading, and a pool whose copies have
    /// all expired loses its row instead of getting its missing window back.
    func testTheFleetMergeDropsACopyOfAPeriodThatEnded() {
        let iso = ISO8601DateFormatter()
        let clock = Date()
        let live = QuotaWindow(
            id: "xai:subscription",
            provider: "xAI",
            providerKey: "xai",
            label: "7-day window",
            remainingPercent: 91,
            resetAt: iso.string(from: clock.addingTimeInterval(6 * 86_400)),
            window: "weekly",
            occurredAt: iso.string(from: clock.addingTimeInterval(-60)),
            producerInstanceId: "other-mac",
            machine: "Other Mac"
        )
        let dead = QuotaWindow(
            id: "xai-subscription",
            provider: "xAI",
            providerKey: "xai",
            label: "7-day window",
            remainingPercent: 0,
            resetAt: iso.string(from: clock.addingTimeInterval(-86_400)),
            window: "weekly",
            occurredAt: iso.string(from: clock.addingTimeInterval(-6 * 86_400)),
            producerInstanceId: "other-mac",
            machine: "Other Mac"
        )
        let split = FleetOrigin.split([live, dead], host: "this-mac")
        XCTAssertEqual(split.groups.flatMap { $0.windows }.map(\.id), ["xai:subscription"],
                       "a copy of a period that ended is not a reading, so it never reaches a row")
        XCTAssertEqual(split.ownPush.count, 0,
                       "neither copy is this Mac's own push, so both are the fleet's to judge")
    }

    /// This Mac's own expired reading keeps its row.  The row greys the last
    /// reading out and waits for a refresh instead of dropping to a dash, which
    /// is what `QuotaWindowSnapshot.freshness == .awaitingRefresh` is for.
    func testAProviderSectionKeepsThisMacsOwnExpiredWindow() {
        let iso = ISO8601DateFormatter()
        let expired = QuotaWindow(
            id: "local-mac:xai:subscription",
            provider: "xAI",
            providerKey: "xai",
            label: "7-day window",
            remainingPercent: 91,
            resetAt: iso.string(from: now.addingTimeInterval(-86_400)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-6 * 86_400))
        )
        let section = QuotaResponse(generatedAt: "now", windows: [expired])
            .platformSections(now: now).first(where: { $0.providerKey == "xai" })!
        XCTAssertFalse(section.windows.isEmpty,
                       "this Mac's own expired reading keeps its row rather than going missing")
        XCTAssertFalse(section.isMissing,
                       "the row is present, so it is not a missing section")
        XCTAssertEqual(section.windows.first?.freshness, .awaitingRefresh,
                       "the expired reading waits for a refresh instead of being thrown away")
        XCTAssertEqual(section.windows.first?.remainingPercent, 91,
                       "the last reading is still what the row shows")
    }

    /// An Antigravity pool whose copies have all expired still gets its
    /// missing window back, so the pool row survives and its weekly state is
    /// not lost.  The copies are dropped before the Antigravity groups are
    /// normalized, which is what lets the placeholder be regenerated.
    func testAnAntigravityPoolWhoseCopiesAllExpiredKeepsItsMissingWindow() {
        let iso = ISO8601DateFormatter()
        let clock = Date()
        func poolWindow(_ id: String, _ family: String, _ period: String, percent: Double,
                        resetIn: TimeInterval, observedAgo: TimeInterval) -> QuotaWindow {
            QuotaWindow(
                id: id,
                provider: "Antigravity",
                providerKey: "google-antigravity",
                modelType: family,
                label: "\(family) Models · \(period)",
                remainingPercent: percent,
                resetAt: iso.string(from: clock.addingTimeInterval(resetIn)),
                window: period,
                occurredAt: iso.string(from: clock.addingTimeInterval(-observedAgo)),
                producerInstanceId: "other-mac",
                machine: "Other Mac"
            )
        }
        let expiredGemini5h = poolWindow("ag:gemini:5h", "gemini", "5h", percent: 0,
                                         resetIn: -86_400, observedAgo: 6 * 86_400)
        let expiredGeminiWeekly = poolWindow("ag:gemini:weekly", "gemini", "weekly", percent: 0,
                                             resetIn: -86_400, observedAgo: 6 * 86_400)
        let liveThirdParty = poolWindow("ag:third-party:weekly", "third-party", "weekly", percent: 40,
                                        resetIn: 6 * 86_400, observedAgo: 60)

        let split = FleetOrigin.split([expiredGemini5h, expiredGeminiWeekly, liveThirdParty],
                                      host: "this-mac")
        let merged = split.ownPush + split.groups.flatMap { $0.windows }
        let section = QuotaResponse(generatedAt: "now", windows: merged)
            .platformSections(now: clock).first(where: { $0.providerKey == "google-antigravity" })!
        let pools = AntigravityQuotaGroups.pools(from: section.windows.map(\.window), now: clock)
        let gemini = pools.first(where: { $0.key == "gemini" })
        XCTAssertNotNil(gemini,
                        "a pool whose copies all expired still gets its missing window back, so the row survives")
        XCTAssertTrue(gemini?.windows.contains(where: { $0.window == "weekly" }) == true,
                      "the pool keeps its weekly window, so its weekly state is not lost")
    }

    /// A period that rolls over must not blank the row:  a window whose reset
    /// passed moments ago was observed moments ago as well, so it stays and
    /// keeps its `due` caption.
    func testAProviderSectionKeepsAWindowWhoseResetJustPassed() {
        let iso = ISO8601DateFormatter()
        let rolling = QuotaWindow(
            id: "xai:subscription",
            provider: "xAI",
            providerKey: "xai",
            label: "5-hour window",
            remainingPercent: 0,
            resetAt: iso.string(from: now.addingTimeInterval(-1)),
            window: "5h",
            occurredAt: iso.string(from: now.addingTimeInterval(-5))
        )
        let section = QuotaResponse(generatedAt: "now", windows: [rolling])
            .platformSections(now: now).first(where: { $0.providerKey == "xai" })!
        XCTAssertEqual(section.windows.count, 1,
                       "a window whose reset just passed was observed just now, so the row keeps it")
    }

    func testEndpointRestrictions() {
        XCTAssertTrue(QuotaClient.isAllowedEndpoint(URL(string: "https://usage.example/api/quota-windows")!))
        XCTAssertTrue(QuotaClient.isAllowedEndpoint(URL(string: "http://localhost:3000/api/quota-windows")!))
        XCTAssertTrue(QuotaClient.isAllowedEndpoint(URL(string: "http://127.0.0.1/api/quota-windows")!))
        XCTAssertTrue(QuotaClient.isAllowedEndpoint(URL(string: "http://[::1]/api/quota-windows")!))
        XCTAssertFalse(QuotaClient.isAllowedEndpoint(URL(string: "http://usage.example/api")!))
        XCTAssertFalse(QuotaClient.isAllowedEndpoint(URL(string: "https://user:pass@usage.example/api")!))
        XCTAssertFalse(QuotaClient.isAllowedEndpoint(URL(string: "https://usage.example/api?token=secret")!))
        XCTAssertFalse(QuotaClient.isAllowedEndpoint(URL(string: "https://usage.example/api#fragment")!))
    }

    func testUnauthorizedAndRedirectAreRejectedWithoutFollowingRedirect() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/unauthorized" {
                return StubURLProtocol.reply(status: 401, body: Data())
            }
            return StubURLProtocol.reply(status: 302, headers: ["Location": "https://evil.example/collect"], body: Data())
        }
        let unauthorized = try QuotaClient(endpoint: URL(string: "http://localhost/unauthorized")!, token: "secret", urlProtocolClasses: [StubURLProtocol.self])
        do {
            _ = try await unauthorized.fetch()
            XCTFail("expected 401")
        } catch let error as QuotaClientError {
            XCTAssertEqual(error, .unauthorized)
        }

        let redirect = try QuotaClient(endpoint: URL(string: "http://localhost/redirect")!, token: "secret", urlProtocolClasses: [StubURLProtocol.self])
        do {
            _ = try await redirect.fetch()
            XCTFail("expected redirect rejection")
        } catch let error as QuotaClientError {
            XCTAssertEqual(error, .httpStatus(302))
        }
        XCTAssertEqual(StubURLProtocol.seenURLs, ["/unauthorized", "/redirect"])
    }

    func testMalformedAndOversizedResponsesAreRejected() async throws {
        StubURLProtocol.handler = { _ in StubURLProtocol.reply(status: 200, body: Data(repeating: 0x78, count: 32)) }
        let malformed = try QuotaClient(endpoint: URL(string: "http://localhost/malformed")!, token: "secret", urlProtocolClasses: [StubURLProtocol.self])
        do {
            _ = try await malformed.fetch()
            XCTFail("expected malformed")
        } catch let error as QuotaClientError {
            XCTAssertEqual(error, .malformedResponse)
        }

        StubURLProtocol.handler = { _ in StubURLProtocol.reply(status: 200, body: Data(repeating: 0x78, count: 33)) }
        let oversized = try QuotaClient(endpoint: URL(string: "http://localhost/large")!, token: "secret", maxResponseBytes: 32, urlProtocolClasses: [StubURLProtocol.self])
        do {
            _ = try await oversized.fetch()
            XCTFail("expected oversized")
        } catch let error as QuotaClientError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static var handler: ((URLRequest) -> Reply)?
    static var seenURLs: [String] = []

    static func reply(status: Int, headers: [String: String] = [:], body: Data) -> Reply {
        Reply(status: status, headers: headers, body: body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.seenURLs.append(url.path)
        let reply = Self.handler?(request) ?? Self.reply(status: 500, body: Data())
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
