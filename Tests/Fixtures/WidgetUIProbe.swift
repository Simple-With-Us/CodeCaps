import SwiftUI
import AppKit
import WidgetKit
import AppIntents
@main struct Gallery {
 @MainActor static func checkSemantics() async throws {
  let stamp = ISO8601DateFormatter().string(from: Date())
  let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
  func wire(_ id: String, _ provider: String, _ token: String?, _ percent: Double?,
            _ label: String = "Quota", model: String? = nil, source: String? = nil) -> [String: Any] {
   var value: [String: Any] = ["id":id, "provider":provider, "providerKey":provider,
       "label":label, "occurredAt":stamp, "reportedAt":stamp, "resetAt":reset]
   value["window"] = token; value["remainingPercent"] = percent
   value["modelId"] = model; value["source"] = source
   return value
  }
  let payload = [
   wire("claude:plan-metadata", "anthropic", nil, nil, "Plan Details"),
   wire("claude:5h", "anthropic", "5h", 80), wire("claude:7d", "anthropic", "7d", 0),
   wire("claude:7d:missing", "anthropic", "7d", nil),
   wire("claude:fable", "anthropic", "7d", 0, model:"Fable"),
   wire("plan", "minimax", nil, nil, "Plan"), wire("minimax:5h", "minimax", "5h", 92),
   wire("minimax:video", "minimax", "1d", 100, "Video", model:"hailuo"),
   wire("minimax:7d", "minimax", "7d", 74),
   wire("raw:gemini:5h", "google-antigravity", "5h", 7, "Gemini 5-hour"),
   wire("antigravity:gemini:5h", "google-antigravity", "5h", 63, "Gemini Models · 5-hour"),
   wire("antigravity:gemini:weekly", "google-antigravity", "7d", 1, "Gemini Models · Weekly"),
   wire("gemini:argon", "google-antigravity", "5h", 0, "Gemini Argon", model:"Argon"),
   wire("mirror:github-copilot", "github-copilot", "1m", 0),
   wire("local-mac:github-copilot", "github-copilot", "1m", 100, source:"CodeCaps")
  ]
  let parsed = WidgetPresentation.parseSnapshot(data: try JSONSerialization.data(withJSONObject:["windows":payload]))
  let claude = parsed.first { $0.providerKey == "anthropic" }!
  precondition(claude.primaryWindows.count == 2 && claude.detailWindows.map(\.label) == ["Fable limit"])
  precondition(claude.dualWindows()?.window2.id == "claude:7d")
  precondition(claude.atCapWindow()?.id == "claude:7d")
  let minimax = parsed.first { $0.providerKey == "minimax" }!
  precondition(minimax.windows.count == 3 && !minimax.hasModelDetails && minimax.remainingPercent == 74)
  // The supplementary video daily never takes a bar from the plan's own
  // windows:  the pair stays the 5-hour and weekly coding windows (owner
  // 2026-11-06: "Widget says 1d instead of 7d").
  precondition(minimax.dualWindows()?.window1.id == "minimax:5h")
  precondition(minimax.dualWindows()?.window2.id == "minimax:7d")
  let gemini = parsed.first { $0.id == "antigravity-gemini" }!
  precondition(gemini.primaryWindows.map(\.remainingPercent) == [63, 1])
  precondition(gemini.remainingPercent == 1 && gemini.detailWindows.map(\.label) == ["Argon limit"])
  precondition(gemini.atCapWindow() == nil)
  let copilot = parsed.first { $0.providerKey == "github-copilot" }!
  precondition(copilot.title == "GitHub Copilot" && copilot.remainingPercent == 100)
  precondition(copilot.primaryWindows.count == 1 && !copilot.hasModelDetails)
  let week = CompanionWindowItem(id:"weekly", label:"7-day", cadence:"7d", remainingPercent:57,
       resetAt:Date().addingTimeInterval(3600), reportedAt:Date())
  let plan = CompanionWindowItem(id:"plan", label:"Plan", cadence:"Plan", remainingPercent:nil, resetAt:nil)
  let fable = CompanionWindowItem(id:"fable", label:"Fable limit", cadence:"7d", remainingPercent:0,
       resetAt:Date().addingTimeInterval(3600), isSubModelLimit:true, reportedAt:Date())
  let phone = CompanionQuotaItem(id:"anthropic", providerKey:"anthropic", title:"Claude Code", subtitle:nil,
       remainingPercent:0, resetAt:nil, isExhausted:false, isAlarmEnabled:false, windows:[plan,week,fable])
  precondition(phone.cardShortWindow(scope:.allSources)?.window.id == "weekly")
  precondition(phone.cardLongWindow(scope:.allSources) == nil && phone.cardRemainingPercent(scope:.allSources) == 57)
  precondition(phone.isExpandable && phone.cardDetailWindows(scope:.allSources).map(\.label) == ["Fable limit"])
  let weeklyHealthy = WidgetWindowItem(id:"weekly", label:"Weekly", cadence:"7d", remainingPercent:47, resetAt:nil)
  let positiveExtra = WidgetWindowItem(id:"extra", label:"Additional tokens", cadence:"Other limit", remainingPercent:81,
       resetAt:nil, isExtraAllowance:true)
  let healthyMuse = WidgetPlatformItem(id:"muse-assist", providerKey:"muse-assist", title:"Muse Assist", subtitle:"",
       remainingPercent:47, resetAt:nil, windows:[weeklyHealthy,positiveExtra])
  precondition(healthyMuse.controllingWindow()?.id == "weekly")
  precondition(WidgetPresentation.displayPercent(percent:.nan,isMasked:false) == "—")
  print("PASS: sanitized parser and companion selection preserve primary quotas, Fable, Argon and Mac precedence")
  let missing=WidgetWindowItem(id:"missing",label:"Other limit",cadence:"Other limit",remainingPercent:nil,resetAt:nil)
  let zero=WidgetWindowItem(id:"zero",label:"7-day",cadence:"7d",remainingPercent:0,resetAt:nil)
  let extra=WidgetWindowItem(id:"extra",label:"Other limit",cadence:"Other limit",remainingPercent:83,resetAt:nil,isExtraAllowance:true)
  precondition(missing.displayPercent == "—")
  precondition(zero.displayPercent == "0%")
  precondition(extra.displayPercent == "83%")
  precondition(missing.cadenceToken == "Limit")
  precondition(extra.cadenceToken == "Extra")
  let countedExtra = WidgetWindowItem(id:"count-extra",label:"Other limit",cadence:"Other limit",remainingPercent:nil,resetAt:nil,isExtraAllowance:true,absoluteRemaining:42)
  let counted = WidgetPlatformItem(id:"counted",providerKey:"muse-assist",title:"Muse Assist",subtitle:"",remainingPercent:0,resetAt:nil,windows:[zero,countedExtra])
  precondition(countedExtra.displayPercent == "42 left")
  precondition(countedExtra.isCountOnly)
  precondition(counted.controllingWindow(.mostHeadroom)?.id == zero.id)
  precondition(counted.usableMuseExtra?.absoluteRemaining == 42)
  precondition(counted.windows.last?.absoluteRemaining == 42)
  precondition(counted.dualWindows() != nil)
  precondition(!ShowWidgetPlanDetailIntent.openAppWhenRun)
  let defaults=UserDefaults(suiteName:WidgetSnapshotStore.appGroupId)!
  let scope="native-regression-"+UUID().uuidString
  defer { defaults.removeObject(forKey:"widgetDetail:"+scope) }
  _ = try await ShowWidgetPlanDetailIntent(planID:"extra",overviewKey:scope).perform()
  precondition(defaults.string(forKey:"widgetDetail:"+scope) == "extra")
  _ = try await ShowWidgetPlanDetailIntent(planID:"",overviewKey:scope).perform()
  precondition(defaults.string(forKey:"widgetDetail:"+scope) == nil)
  print("PASS: missing/zero/extra captions and intent select/back persistence")
 }
 @MainActor static func main() async throws {
  try await checkSemantics()
  let now=Date()
  var platforms = [WidgetPlatformItem(id:"claude",providerKey:"anthropic",title:"Claude",subtitle:"",remainingPercent:85,resetAt:now.addingTimeInterval(12000),windows:[
   WidgetWindowItem(id:"claude-5h",label:"5-hour",cadence:"5h",remainingPercent:85,resetAt:now.addingTimeInterval(12000)),
   WidgetWindowItem(id:"claude-7d",label:"7-day",cadence:"7d",remainingPercent:nil,resetAt:now.addingTimeInterval(400000))
  ]), WidgetPlatformItem(id:"muse-assist",providerKey:"muse-assist",title:"Muse Assist",subtitle:"",remainingPercent:0,resetAt:now.addingTimeInterval(364000),windows:[
   WidgetWindowItem(id:"weekly",label:"Weekly",cadence:"7d",remainingPercent:0,resetAt:now.addingTimeInterval(364000)),
   WidgetWindowItem(id:"extra",label:"Extra balance",cadence:"Other limit",remainingPercent:nil,resetAt:nil,isExtraAllowance:true,absoluteRemaining:42)
  ])]
  let edgePlatforms = platforms
  platforms += WidgetPresentation.placeholders
  platforms.append(WidgetPlatformItem(id:"overflow",providerKey:"codex",title:"Overflow plan",subtitle:"",remainingPercent:50,resetAt:nil,windows:[]))
  precondition(edgePlatforms[1].usableMuseExtra?.absoluteRemaining == 42)
  precondition(edgePlatforms[1].atCapWindow()?.remainingPercent == 0)
  precondition(platforms[1].usableMuseExtra?.absoluteRemaining == 42)
  precondition(platforms[1].atCapWindow()?.remainingPercent == 0)
  let entry=CodeCapsWidgetEntry(date:Date(),platforms:platforms,lastUpdated:Date())
  for (name,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
   let view=HStack(alignment:.top,spacing:20) {
    VStack {
     Text("Large overview").font(.caption)
     OverviewLargeView(entry:entry).frame(width:338,height:354)
    }
    VStack {
     Text("In-widget plan details").font(.caption)
     WidgetPlanDetailView(platform:platforms[0],entry:entry).padding(14).frame(width:338,height:354)
    }
   }.padding(16).background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme,scheme)
   let renderer=ImageRenderer(content:view);renderer.scale=2
   guard let img=renderer.cgImage else {fatalError("render unavailable")}
   let rep=NSBitmapImageRep(cgImage:img)
   try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"\(ProcessInfo.processInfo.environment["CODECAPS_WIDGET_RENDER_DIR"] ?? NSTemporaryDirectory())/widget-gallery-"+name+".png"))
  }
 }
}
