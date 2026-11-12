import XCTest
@testable import CodeCaps
import QuotaCore

/// BOTFLEET-5B: the widget snapshot de-duplication ran on the main actor and
/// was quadratic in the size of a fleet pull, hanging the app.
@MainActor
final class WidgetSnapshotDedupTests: XCTestCase {
    private func window(_ id: String, provider: String = "Claude", label: String = "5h",
                        percent: Double? = 50) -> QuotaWindow {
        QuotaWindow(id: id, provider: provider, label: label, remainingPercent: percent,
                    occurredAt: "2026-10-22T19:33:50Z")
    }

    func testUniqueWindowsDropsExactDuplicatesAndKeepsOrder() {
        let a = window("a"), b = window("b"), c = window("c", provider: "Codex")
        XCTAssertEqual(MonitorModel.uniqueWindows([a, b, a, c, b, a]), [a, b, c])
    }

    func testUniqueWindowsKeepsWindowsThatShareABucketButDiffer() {
        let first = window("a", percent: 40)
        let second = window("a", percent: 60)
        XCTAssertEqual(MonitorModel.uniqueWindows([first, second, first]), [first, second])
    }

    func testUniqueWindowsMatchesQuadraticReferenceOnLargeFleet() {
        var candidates: [QuotaWindow] = []
        for index in 0..<5_000 {
            candidates.append(window("w\(index % 1_500)", provider: index % 2 == 0 ? "Claude" : "Codex",
                                     percent: Double(index % 3)))
        }
        var reference: [QuotaWindow] = []
        for window in candidates.prefix(600) where !reference.contains(window) { reference.append(window) }
        XCTAssertEqual(MonitorModel.uniqueWindows(Array(candidates.prefix(600))), reference)

        let started = Date()
        let unique = MonitorModel.uniqueWindows(candidates)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(unique.count, Set(candidates.map { "\($0.id)|\($0.provider)|\($0.remainingPercent ?? -1)" }).count)
    }
}
