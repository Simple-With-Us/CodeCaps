import XCTest
@testable import CodeCaps
import QuotaCore

/// `sections` and `displaySections` are memoized on the model because every
/// Glance row, the runaway footer and the menu-bar options read them, and
/// rebuilding them on each read hung the main thread (CodeCaps build 312).
/// These tests pin the invalidation: the cached value must always equal a
/// fresh build from the current `response`, `now` and `platformOrder`.
@MainActor
final class SectionsCacheTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.jays.agent-bar.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func window(id: String, remaining: Double) -> QuotaWindow {
        QuotaWindow(
            id: id,
            provider: "Grok",
            providerKey: "grok-bot",
            providerLabel: "Grok",
            via: "Grok",
            sourceApp: "test",
            label: id,
            remainingPercent: remaining,
            remainingUnknown: false,
            occurredAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_000_000)),
            source: "Grok CLI"
        )
    }

    private func inject(_ model: MonitorModel, _ windows: [QuotaWindow], now: Date) {
        let response = QuotaResponse(
            generatedAt: ISO8601DateFormatter().string(from: now),
            windows: windows
        )
        model.injectForTests(sections: response.platformSections(now: now), now: now)
    }

    /// Rows built by a second, never-read model with the same response, clock
    /// and platform order, so the expected value never comes from the cache
    /// under test.
    private func freshDisplaySections(_ model: MonitorModel) -> [DisplaySection] {
        let fresh = MonitorModel(defaults: defaults)
        fresh.platformOrder = model.platformOrder
        fresh.injectForTests(sections: model.response.platformSections(now: model.now), now: model.now)
        return fresh.displaySections
    }

    func testSectionsFollowEachNewResponse() {
        let model = MonitorModel(defaults: defaults)
        let now = Date()
        inject(model, [window(id: "a", remaining: 60)], now: now)
        // Prime the cache.
        _ = model.displaySections
        XCTAssertTrue(model.sections.flatMap(\.windows).contains { $0.remainingPercent == 60 })

        inject(model, [window(id: "a", remaining: 25)], now: now)
        let remaining = model.sections.flatMap(\.windows).compactMap(\.remainingPercent)
        XCTAssertTrue(remaining.contains(25))
        XCTAssertFalse(remaining.contains(60))
        XCTAssertEqual(model.sections, model.response.platformSections(now: model.now))
        XCTAssertEqual(model.displaySections, freshDisplaySections(model))
    }

    func testSectionsFollowTheClock() {
        let model = MonitorModel(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)
        inject(model, [window(id: "a", remaining: 40)], now: start)
        let cached = model.sections
        _ = model.displaySections

        // Move only the clock: the response stays the same, so this checks
        // the `now` invalidation on its own.
        let later = Date(timeIntervalSince1970: 1_000_000 + 7 * 86_400)
        XCTAssertNotEqual(
            model.response.platformSections(now: start),
            model.response.platformSections(now: later),
            "fixture must change with the clock for this test to mean anything"
        )
        model.injectNowForTests(later)
        XCTAssertEqual(model.now, later)
        XCTAssertNotEqual(model.sections, cached)
        XCTAssertEqual(model.sections, model.response.platformSections(now: later))
        XCTAssertEqual(model.displaySections, freshDisplaySections(model))
    }

    func testPlatformOrderChangeReordersCachedSections() throws {
        let model = MonitorModel(defaults: defaults)
        inject(model, [window(id: "a", remaining: 50)], now: Date())
        let keys = model.sections.map(\.providerKey)
        try XCTSkipIf(Set(keys).count < 2, "needs two platforms to reorder")

        let reversed = Array(keys.reversed())
        model.platformOrder = reversed
        XCTAssertEqual(model.sections.map(\.providerKey), reversed)
        XCTAssertEqual(model.displaySections, freshDisplaySections(model))

        model.platformOrder = []
        XCTAssertEqual(model.sections, model.response.platformSections(now: model.now))
    }

    func testRepeatedReadsReturnTheSameRows() {
        let model = MonitorModel(defaults: defaults)
        inject(model, [window(id: "a", remaining: 70)], now: Date())
        let first = model.displaySections
        for _ in 0..<5 {
            XCTAssertEqual(model.displaySections, first)
        }
    }
}
