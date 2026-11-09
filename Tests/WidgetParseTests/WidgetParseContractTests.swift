import XCTest

/// Wire-parse contract for the iOS widget's snapshot path.  The parse-path
/// sources are mirrored into this target at build time (from
/// ios/CodeCapsCompanion/Widgets and Sources/QuotaCore, see
/// Plugins/WidgetParseMirrorGen) because the iOS
/// companion is built by xcodebuild, not SPM:  without this target the whole
/// parse path - the code that feeds every widget pixel - had no CI coverage,
/// which is how PR #357 broke the iOS build invisibly for days.
final class WidgetParseContractTests: XCTestCase {

    /// The package root, resolved from this file's build-time path, so the
    /// committed wire fixtures load no matter where the test process starts.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WidgetParseTests dir
            .deletingLastPathComponent()  // Tests dir
            .deletingLastPathComponent()  // package root
    }

    private func wire(_ id: String, _ provider: String, _ token: String?, _ percent: Double?,
                      _ label: String = "Quota", model: String? = nil, source: String? = nil,
                      stamp: String, reset: String) -> [String: Any] {
        var value: [String: Any] = ["id": id, "provider": provider, "providerKey": provider,
                                    "label": label, "occurredAt": stamp, "reportedAt": stamp, "resetAt": reset]
        value["window"] = token
        value["remainingPercent"] = percent
        value["modelId"] = model
        value["source"] = source
        return value
    }

    /// The antigravity pool through the real parse path:  one Argon detail
    /// (never a duplicate), the exported pool rows winning the meters, and a
    /// spent detail never dragging the pool headline to zero.
    func testAntigravityPoolKeepsSingleArgonDetailAndHonestHeadline() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let payload = [
            wire("claude:plan-metadata", "anthropic", nil, nil, "Plan Details", stamp: stamp, reset: reset),
            wire("raw:gemini:5h", "google-antigravity", "5h", 7, "Gemini 5-hour", stamp: stamp, reset: reset),
            wire("antigravity:gemini:5h", "google-antigravity", "5h", 63, "Gemini Models 5-hour", stamp: stamp, reset: reset),
            wire("antigravity:gemini:weekly", "google-antigravity", "7d", 1, "Gemini Models Weekly", stamp: stamp, reset: reset),
            wire("gemini:argon", "google-antigravity", "5h", 0, "Gemini Argon", model: "Argon", stamp: stamp, reset: reset),
        ]
        let parsed = WidgetPresentation.parseSnapshot(data: try JSONSerialization.data(withJSONObject: ["windows": payload]))
        let gemini = try XCTUnwrap(parsed.first { $0.id == "antigravity-gemini" })
        // The canonical exported row wins the five-hour meter.
        XCTAssertEqual(gemini.primaryWindows.map(\.remainingPercent), [63, 1])
        // Exactly one Argon detail row.
        XCTAssertEqual(gemini.detailWindows.map(\.label), ["Argon limit"])
        XCTAssertEqual(gemini.windows.filter { $0.id == "gemini:argon" }.count, 1)
        // The spent detail sits beside the pool:  the headline reads the
        // pool's own weekly (1), not the 0% detail, and nothing caps.
        XCTAssertEqual(gemini.remainingPercent, 1)
        XCTAssertNil(gemini.atCapWindow())
    }

    /// A spent sub-model detail never stands in for the pool on the
    /// single-bar row pick:  the small widget's controlling window is the
    /// pool's own most-urgent meter (the 1% weekly), not the 0% Argon
    /// detail (pixel: the small widget headlined "Gemini 5h 0%").
    func testSpentSubModelDetailNeverWinsControllingWindow() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let payload = [
            wire("raw:gemini:5h", "google-antigravity", "5h", 7, "Gemini 5-hour", stamp: stamp, reset: reset),
            wire("antigravity:gemini:5h", "google-antigravity", "5h", 63, "Gemini Models 5-hour", stamp: stamp, reset: reset),
            wire("antigravity:gemini:weekly", "google-antigravity", "7d", 1, "Gemini Models Weekly", stamp: stamp, reset: reset),
            wire("gemini:argon", "google-antigravity", "5h", 0, "Gemini Argon", model: "Argon", stamp: stamp, reset: reset),
        ]
        let parsed = WidgetPresentation.parseSnapshot(data: try JSONSerialization.data(withJSONObject: ["windows": payload]))
        let gemini = try XCTUnwrap(parsed.first { $0.id == "antigravity-gemini" })
        XCTAssertEqual(gemini.controllingWindow()?.id, "antigravity:gemini:weekly")
        XCTAssertEqual(gemini.controllingWindow()?.remainingPercent, 1)
    }

    /// The qa3 wire capture (committed verbatim):  the MiniMax plan keeps its
    /// 5h and weekly rows, both video cadences stay as separate flagged rows,
    /// the reading-less unknown row earns no row, and Copilot keeps buckets.
    func testQA3WireFixtureMiniMaxRowsAndVideoFlags() throws {
        let fxNow = ISO8601DateFormatter().date(from: "2026-11-06T07:50:00Z")!
        let fxData = try Data(contentsOf: packageRoot.appendingPathComponent("Tests/Fixtures/qa3-wire-regression-fixture.json"))
        let fx = WidgetPresentation.parseSnapshot(data: fxData, now: fxNow)
        let minimax = try XCTUnwrap(fx.first { $0.providerKey.contains("minimax") || $0.id.contains("minimax") })
        let ids = minimax.windows.map { $0.id }
        let phone5h = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"general\"]"
        let macWeekly = "[\"producer\",\"Mac.Jays.Services\",\"general\"]"
        let phoneVideo = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"video\"]"
        let macVideo = "[\"producer\",\"Mac.Jays.Services\",\"video\"]"
        XCTAssertEqual(minimax.windows.count, 4, "5h plan, 7d plan, 1d video, 7d video: \(ids)")
        XCTAssertTrue(ids.contains(phone5h), "the fresher codecaps copy wins the merged 5h plan row: \(ids)")
        XCTAssertEqual(minimax.windows.first { $0.id == macWeekly }?.remainingPercent, 5)
        XCTAssertTrue(ids.contains(phoneVideo) && ids.contains(macVideo), "both video cadences keep rows: \(ids)")
        XCTAssertEqual(minimax.windows.filter { $0.isSupplementaryVideoQuota }.count, 2, "both video rows flagged")
        XCTAssertEqual(minimax.windows.filter { !$0.isSupplementaryVideoQuota }.count, 2, "exactly the two plan rows unflagged")
        XCTAssertEqual(minimax.dualWindows()?.window1.id, phone5h, "the pair opens on the plan 5h")
        XCTAssertEqual(minimax.dualWindows()?.window2.id, macWeekly, "the pair holds the plan weekly, never a video row")
        XCTAssertNil(minimax.atCapWindow(now: fxNow), "video rows never cap the plan")
        let copilot = try XCTUnwrap(fx.first { $0.providerKey.contains("copilot") || $0.id.contains("copilot") })
        XCTAssertEqual(copilot.windows.count, 3, "copilot buckets keep rows")
        XCTAssertTrue(copilot.windows.contains { $0.remainingPercent == 0 }, "the exhausted Premium row stays visible")
    }

    /// The qa6 wire captures:  a spent video pool never caps or outranks a
    /// live plan, a spent plan caps itself, and a video-only platform keeps
    /// its cap through the all-window fallback.
    func testQA6VideoCapStateExclusion() throws {
        let q6Now = ISO8601DateFormatter().date(from: "2026-11-06T10:30:00Z")!
        func load(_ name: String) throws -> [WidgetPlatformItem] {
            try WidgetPresentation.parseSnapshot(data: Data(contentsOf: packageRoot.appendingPathComponent("qa6-harness/" + name)), now: q6Now)
        }
        let phone5h = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"general\"]"
        let macWeekly = "[\"producer\",\"Mac.Jays.Services\",\"general\"]"
        let phoneVideo = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"video\"]"
        let q6a = try XCTUnwrap(load("qa6-a-spent-video-live-plan.json").first { $0.providerKey == "minimax" })
        XCTAssertEqual(q6a.windows.count, 4)
        XCTAssertEqual(q6a.windows.filter { $0.isSupplementaryVideoQuota }.count, 2)
        XCTAssertNil(q6a.atCapWindow(now: q6Now), "spent video must not cap a live plan")
        XCTAssertEqual(q6a.remainingPercent, 5, "headline derives from plan windows, not the spent video")
        XCTAssertFalse(q6a.isExhausted)
        XCTAssertEqual(q6a.dualWindows()?.window1.id, phone5h)
        XCTAssertEqual(q6a.controllingWindow(.mostUrgent)?.id, macWeekly)
        XCTAssertEqual(q6a.controllingWindow(.mostHeadroom)?.id, phone5h)
        let q6b = try XCTUnwrap(load("qa6-b-spent-plan-live-video.json").first { $0.providerKey == "minimax" })
        XCTAssertEqual(q6b.atCapWindow(now: q6Now)?.id, phone5h, "the spent plan 5h caps the platform")
        XCTAssertTrue(q6b.isExhausted)
        XCTAssertEqual(q6b.controllingWindow(.mostUrgent)?.id, phone5h)
        let q6c = try XCTUnwrap(load("qa6-c-video-only-spent.json").first { $0.providerKey == "minimax" })
        XCTAssertEqual(q6c.windows.count, 1)
        XCTAssertEqual(q6c.atCapWindow(now: q6Now)?.id, phoneVideo, "video-only fallback binds the video window")
        XCTAssertTrue(q6c.isExhausted)
    }

    /// The qa4 capture:  one xAI subscription pool seen by two producers
    /// merges to one 7d row, the fresher phone copy winning.
    func testQA4XaiPoolMergesAcrossProducers() throws {
        let xaiNow = ISO8601DateFormatter().date(from: "2026-11-06T09:25:00Z")!
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Tests/Fixtures/qa4-xai-wire-counterexample.json"))
        let parsed = WidgetPresentation.parseSnapshot(data: data, now: xaiNow)
        let xai = try XCTUnwrap(parsed.first { $0.providerKey == "xai" })
        XCTAssertEqual(xai.windows.count, 1, "the two producer copies of one pool must merge")
        XCTAssertEqual(xai.windows.first?.id, "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"grok:subscription\"]")
        XCTAssertEqual(xai.windows.first?.remainingPercent, 79)
    }

    /// The phone's companion card model:  sub-model limits are expandable
    /// details beside the card, never headline meters;  a count-only extra
    /// shows its "N left" caption but fills no meter-pair slot (#360).
    func testCompanionCardDetailsAndCaptions() {
        let week = CompanionWindowItem(id: "weekly", label: "7-day", cadence: "7d", remainingPercent: 57,
                                       resetAt: Date().addingTimeInterval(3600), reportedAt: Date())
        let plan = CompanionWindowItem(id: "plan", label: "Plan", cadence: "Plan", remainingPercent: nil, resetAt: nil)
        let fable = CompanionWindowItem(id: "fable", label: "Fable limit", cadence: "7d", remainingPercent: 0,
                                        resetAt: Date().addingTimeInterval(3600), isSubModelLimit: true, reportedAt: Date())
        let phone = CompanionQuotaItem(id: "anthropic", providerKey: "anthropic", title: "Claude Code", subtitle: nil,
                                       remainingPercent: 0, resetAt: nil, isExhausted: false, isAlarmEnabled: false,
                                       windows: [plan, week, fable])
        XCTAssertEqual(phone.cardShortWindow(scope: .allSources)?.window.id, "weekly")
        XCTAssertNil(phone.cardLongWindow(scope: .allSources))
        XCTAssertEqual(phone.cardRemainingPercent(scope: .allSources), 57)
        XCTAssertTrue(phone.isExpandable)
        XCTAssertEqual(phone.cardDetailWindows(scope: .allSources).map(\.label), ["Fable limit"])

        let zero = WidgetWindowItem(id: "zero", label: "7-day", cadence: "7d", remainingPercent: 0, resetAt: nil)
        let countedExtra = WidgetWindowItem(id: "count-extra", label: "Other limit", cadence: "Other limit",
                                            remainingPercent: nil, resetAt: nil, isExtraAllowance: true,
                                            absoluteRemaining: 42)
        XCTAssertEqual(countedExtra.displayPercent, "42 left")
        let counted = WidgetPlatformItem(id: "counted", providerKey: "muse-assist", title: "Muse Assist",
                                         subtitle: "", remainingPercent: 0, resetAt: nil,
                                         windows: [zero, countedExtra])
        XCTAssertNil(counted.dualWindows(), "a count-only extra fills no meter-pair slot (QuotaWindowPairing, #360)")
    }

    /// A spent scoped pool (Codex's Code Review bucket) is not the plan's
    /// quota:  it earns no row, cannot cap the plan and cannot drag the
    /// headline - the phone's intake and the shared gate agree (PR #376,
    /// Kody review on this PR).  And a producer-scoped plan-metadata id is
    /// serialized JSON, so the metadata marker must match inside the id, not
    /// only at its tail.
    func testScopedPoolsAndJsonMetadataIdsStayOutOfIntake() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        // The id shape the fleet actually ships (qa3 wire fixture).
        let metadataJsonId = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"minimax:plan-metadata\"]"
        let payload = [
            wire("openai:subscription", "openai", "5h", 62, "5-hour window", stamp: stamp, reset: reset),
            wire("openai:code-review", "openai", "7d", 0, "Code Review", stamp: stamp, reset: reset),
            wire(metadataJsonId, "minimax", nil, nil, "MiniMax quota", stamp: stamp, reset: reset),
        ]
        let parsed = WidgetPresentation.parseSnapshot(data: try JSONSerialization.data(withJSONObject: ["windows": payload]))
        let codex = try XCTUnwrap(parsed.first { $0.providerKey == "openai" })
        XCTAssertEqual(codex.windows.map(\.id), ["openai:subscription"])
        XCTAssertEqual(codex.remainingPercent, 62)
        XCTAssertNil(codex.atCapWindow())
        let minimax = parsed.first { $0.providerKey == "minimax" }
        XCTAssertTrue(minimax?.windows.isEmpty ?? true, "a JSON-shaped metadata id is a caption, not a window")
    }

    /// The phone's intake is the widget's contract twin:  a JSON-shaped
    /// plan-metadata id that carries a reset date must never become a phone
    /// window either (the reading-less drop only catches figure-less,
    /// reset-less rows).  Drives the phone's real intake predicate.
    @MainActor
    func testPhoneIntakeDropsJsonMetadataIds() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let codingPlan = "[\"producer\",\"Mac.Jays.Services\",\"minimax:coding-plan\"]"
        let metadataJsonId = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"minimax:plan-metadata\"]"
        let payload = [
            wire(codingPlan, "minimax", "5h", 78, "Coding plan (all models)", stamp: stamp, reset: reset),
            wire(metadataJsonId, "minimax", nil, nil, "MiniMax quota", stamp: stamp, reset: reset),
        ]
        let decoder = JSONDecoder()
        var newestDeadCopy: Date? = nil
        let admitted = try payload.map {
            try decoder.decode(CompanionQuotaModel.WireRawWindow.self, from: JSONSerialization.data(withJSONObject: $0))
        }.filter {
            CompanionQuotaModel.admitsToIntake($0, providerKey: "minimax", ownInstanceId: nil,
                                               now: Date(), newestDeadCopyObservedAt: &newestDeadCopy)
        }
        XCTAssertEqual(admitted.map(\.id), [codingPlan])
    }
}
