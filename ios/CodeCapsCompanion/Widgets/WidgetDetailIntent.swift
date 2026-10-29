import AppIntents
import Foundation
import WidgetKit

struct ShowWidgetPlanDetailIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Plan Details"
    static var openAppWhenRun: Bool = false
    @Parameter(title: "Plan ID") var planID: String
    @Parameter(title: "Overview") var overviewKey: String
    init() {}
    init(planID: String, overviewKey: String) {
        self.planID = planID
        self.overviewKey = overviewKey
    }
    func perform() async throws -> some IntentResult {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshotStore.appGroupId) else { return .result() }
        let key = "widgetDetail:" + overviewKey
        if planID.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(planID, forKey: key) }
        return .result()
    }
}
