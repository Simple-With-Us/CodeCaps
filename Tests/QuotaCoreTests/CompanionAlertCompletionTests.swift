import XCTest
@testable import QuotaCore

final class CompanionAlertCompletionTests: XCTestCase {
    func testDeferredPopupChecksGenerationCurrentChannelAndActualSource() {
        let sourceA = UUID().uuidString
        let sourceB = UUID().uuidString
        let popupOnly = UsageAlertOption(enabled: true, notification: false, popup: true, sound: .silent)
        XCTAssertTrue(CompanionInAppAlertPolicy.canPresent(option: popupOnly,
            selectedSource: sourceA, reportedSource: sourceA, scheduledGeneration: 4, currentGeneration: 4))
        XCTAssertFalse(CompanionInAppAlertPolicy.canPresent(option: popupOnly,
            selectedSource: sourceA, reportedSource: sourceA, scheduledGeneration: 4, currentGeneration: 5))
        XCTAssertFalse(CompanionInAppAlertPolicy.canPresent(option: popupOnly,
            selectedSource: sourceB, reportedSource: sourceA, scheduledGeneration: 5, currentGeneration: 5))
        XCTAssertFalse(CompanionInAppAlertPolicy.canPresent(option: .init(enabled: false, popup: true),
            selectedSource: nil, reportedSource: sourceA, scheduledGeneration: 5, currentGeneration: 5))
        XCTAssertFalse(CompanionInAppAlertPolicy.canPresent(option: .init(enabled: true, notification: true, popup: false),
            selectedSource: nil, reportedSource: sourceA, scheduledGeneration: 5, currentGeneration: 5))
    }

    func testInterleavedDeviceReadingsCannotResetAnotherDevicesTracker() {
        let now = Date()
        let sourceA = UUID().uuidString
        let sourceB = UUID().uuidString
        var tracker = ResetAlarmTracker()
        func observation(source: String, remaining: Double, reset: Date, at: Date) -> ResetAlarmObservation {
            ResetAlarmObservation(scope: CompanionAlertSourcePolicy.observationScope(reportedInstanceId: source),
                providerId: "anthropic", providerTitle: "Claude", windowId: "weekly", windowLabel: "7d",
                periodSeconds: 604_800, resetAt: reset, remainingPercent: remaining, observedAt: at)
        }
        let resetA = now.addingTimeInterval(86_400)
        XCTAssertTrue(tracker.process([observation(source: sourceA, remaining: 0, reset: resetA, at: now)], now: now).isEmpty)
        let later = now.addingTimeInterval(1)
        XCTAssertTrue(tracker.process([observation(source: sourceB, remaining: 100,
            reset: resetA.addingTimeInterval(604_800), at: later)], now: later).isEmpty)
        XCTAssertTrue(tracker.process([observation(source: sourceA, remaining: 0,
            reset: resetA, at: later.addingTimeInterval(1))], now: later.addingTimeInterval(1)).isEmpty)
        XCTAssertNotEqual(CompanionAlertSourcePolicy.observationIdentity(provider: "anthropic", window: "weekly", reportedInstanceId: sourceA),
                          CompanionAlertSourcePolicy.observationIdentity(provider: "anthropic", window: "weekly", reportedInstanceId: sourceB))
        XCTAssertEqual(CompanionAlertSourcePolicy.instanceId(observationScope:
            CompanionAlertSourcePolicy.observationScope(reportedInstanceId: sourceA)), sourceA.lowercased())
    }

    func testOnlyKnownAntigravityPoolIDsNormalizeForProviderResetChoices() {
        XCTAssertEqual(CompanionAlertSourcePolicy.canonicalResetProvider("google-antigravity:gemini"), "google-antigravity")
        XCTAssertEqual(CompanionAlertSourcePolicy.canonicalResetProvider("google-antigravity:third-party"), "google-antigravity")
        XCTAssertEqual(CompanionAlertSourcePolicy.canonicalResetProvider("custom:pool"), "custom:pool")
    }

    func testInAppAndSystemDeliveryAreIndependent() {
        var option = UsageAlertOption(enabled: true, notification: false, popup: true, sound: .silent)
        XCTAssertTrue(option.hasDelivery)
        XCTAssertTrue(option.wantsInAppMessage)
        XCTAssertFalse(option.wantsSystemNotification)
        option.popup = false
        XCTAssertFalse(option.hasDelivery)
        option.notification = true
        XCTAssertTrue(option.wantsSystemNotification)
        XCTAssertFalse(option.wantsInAppMessage)
        option.enabled = false
        XCTAssertFalse(option.hasDelivery)
    }

    func testUnknownDeviceNeverMatchesAnExplicitSelection() {
        let id = UUID().uuidString.lowercased()
        XCTAssertEqual(CompanionAlertSourcePolicy.sourceInstanceId(alertID: id + "|" + String(repeating: "a", count: 64)), id)
        XCTAssertNil(CompanionAlertSourcePolicy.sourceInstanceId(alertID: id + "|episode"))
        XCTAssertNil(CompanionAlertSourcePolicy.sourceInstanceId(alertID: "MacBook|episode"))
        XCTAssertNil(CompanionAlertSourcePolicy.sourceInstanceId(alertID: id))
        XCTAssertFalse(CompanionAlertSourcePolicy.matches(selected: id, reported: nil))
        XCTAssertFalse(CompanionAlertSourcePolicy.matches(selected: id, reported: UUID().uuidString))
        XCTAssertTrue(CompanionAlertSourcePolicy.matches(selected: id, reported: id.uppercased()))
        XCTAssertTrue(CompanionAlertSourcePolicy.matches(selected: nil, reported: nil))
    }

    func testPartialPoolBellsNeverEnableWholeProviderRemoteReset() {
        let owners = ["google-antigravity": ["gemini", "third-party"], "anthropic": ["anthropic"]]
        let partial = CompanionAlertSourcePolicy.remoteResetProviders(all: false, selected: ["gemini", "anthropic"],
                                                                     ownerIDsByProvider: owners)
        XCTAssertEqual(partial.providerIDs, ["anthropic"])
        let whole = CompanionAlertSourcePolicy.remoteResetProviders(all: false,
            selected: ["gemini", "third-party"], ownerIDsByProvider: owners)
        XCTAssertEqual(whole.providerIDs, ["google-antigravity"])
        XCTAssertTrue(CompanionAlertSourcePolicy.remoteResetProviders(all: true, selected: [], ownerIDsByProvider: [:]).all)
    }

    func testAdditiveWirePreferencesDecodeLegacyAndRoundTripNewChoices() throws {
        let legacy = try JSONDecoder().decode(UsageAlertPreferences.self, from: Data(#"{"options":{}}"#.utf8))
        XCTAssertNil(legacy.resetProviders)
        XCTAssertNil(legacy.sourceInstanceId)
        var choices = legacy
        choices.resetProviders = .init(all: false, providerIDs: ["anthropic"])
        choices.sourceInstanceId = UUID().uuidString.lowercased()
        choices[.anomaly] = .init(enabled: true, notification: false, popup: true, sound: .glass)
        let encoded = try JSONEncoder().encode(choices)
        XCTAssertEqual(try JSONDecoder().decode(UsageAlertPreferences.self, from: encoded), choices)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((json["resetProviders"] as? [String: Any])?["all"] as? Bool, false)
        XCTAssertEqual(json["sourceInstanceId"] as? String, choices.sourceInstanceId)
    }
}
