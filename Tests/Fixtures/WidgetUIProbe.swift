import SwiftUI
import AppKit
import WidgetKit
import AppIntents
@main struct Gallery {
 @MainActor static func checkSemantics() async throws {
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
  // Selection check only - NOT appended to the gallery array, so the rendered
  // gallery input stays identical to main (placeholders already include a
  // MiniMax row; appending this one rendered a duplicate).  The supplementary
  // video daily never takes a bar from the plan's own windows:  the pair
  // stays the 5-hour and weekly coding windows (owner 2026-11-06: "Widget
  // says 1d instead of 7d").  The video row here carries the rewritten
  // display label the widget actually receives ("1d window" - the rewrite
  // drops the video tokens), so only the carried identity flag keeps it off
  // a bar (Kody review, PR #367).
  let minimaxVideo = WidgetPlatformItem(id:"minimax-video-check",providerKey:"minimax",title:"MiniMax",subtitle:"",remainingPercent:5,resetAt:now.addingTimeInterval(300000),windows:[
   WidgetWindowItem(id:"minimax-5h",label:"5-hour window",cadence:"5h",remainingPercent:81,resetAt:now.addingTimeInterval(7000)),
   WidgetWindowItem(id:"minimax-video",label:"1d window",cadence:"1d",remainingPercent:100,resetAt:now.addingTimeInterval(70000),isSupplementaryVideoQuota:true),
   WidgetWindowItem(id:"minimax-7d",label:"weekly window",cadence:"7d",remainingPercent:5,resetAt:now.addingTimeInterval(300000))
  ])
  precondition(minimaxVideo.dualWindows()?.window1.id == "minimax-5h")
  precondition(minimaxVideo.dualWindows()?.window2.id == "minimax-7d")

  // Wire-level checks through the real parse path:  the payload shape the Mac
  // actually publishes, so construction-time behavior is pinned, not just the
  // post-construction selection above.
  let iso = ISO8601DateFormatter()
  func wireWindow(_ id: String, _ label: String, _ window: String, _ pct: Double, _ resetIn: Double, _ windowKey: String, _ age: Double = 0) -> String {
   "{\"id\":\"\(id)\",\"provider\":\"p\",\"label\":\"\(label)\",\"window\":\"\(window)\",\"remainingPercent\":\(pct),\"resetAt\":\"\(iso.string(from: now.addingTimeInterval(resetIn)))\",\"occurredAt\":\"\(iso.string(from: now.addingTimeInterval(-age)))\",\"windowKey\":\"\(windowKey)\"}"
  }
  // MiniMax, shaped like the actual payload QA reviewed:  the codecaps and
  // collector producers word the SAME allowance differently ("5-hour window"
  // beside "Coding plan (all models)", "7-day window" beside "weekly
  // window"), and the server's canonical windowKey is what says they are one
  // allowance.  The copies must merge onto one row (the fresher collector
  // reading wins), the video identity must be captured before the display
  // rewrite, and the pair must stay the plan's own 5-hour and weekly windows.
  let mmJSON = "{\"windows\":["
   + wireWindow("minimax:5h", "5-hour window", "5h", 81, 7000, "5h", 900) + ","
   + wireWindow("minimax:coding-plan", "Coding plan (all models)", "interval", 77, 7000, "5h") + ","
   + wireWindow("minimax:weekly", "7-day window", "7d", 5, 300000, "7d", 900) + ","
   + wireWindow("minimax:weekly-general", "weekly window", "weekly", 4, 300000, "7d") + ","
   + wireWindow("minimax:hailuo", "Hailuo", "1d", 100, 70000, "1d")
   + "]}"
  let mmPlatforms = WidgetPresentation.parseSnapshot(data: mmJSON.data(using: .utf8)!, now: now)
  let mm = mmPlatforms.first { $0.id.contains("minimax") || $0.providerKey.contains("minimax") }
  precondition(mm?.windows.count == 3, "minimax copies did not merge: \(mm?.windows.count ?? -1)")
  precondition(mm?.windows.contains { $0.id == "minimax:coding-plan" } == true, "the fresher copy should win the 5h row")
  precondition(mm?.windows.contains { $0.id == "minimax:weekly-general" } == true, "the fresher copy should win the 7d row")
  precondition(mm?.windows.first { $0.id == "minimax:hailuo" }?.isSupplementaryVideoQuota == true)
  precondition(mm?.dualWindows()?.window1.id == "minimax:coding-plan")
  precondition(mm?.dualWindows()?.window2.id == "minimax:weekly-general")
  // Copilot: three monthly buckets are three allowances with three canonical
  // keys.  A cadence-only dedupe collapses them into one "1m" row and hides
  // an exhausted Premium behind a 100% Chat row (QA pixel review 2026-11-06).
  let cpJSON = "{\"windows\":["
   + wireWindow("local-mac:github-copilot:premium_interactions", "Premium requests", "monthly", 0, 900000, "other:premium_interactions") + ","
   + wireWindow("local-mac:github-copilot:chat", "Chat requests", "monthly", 100, 900000, "other:chat") + ","
   + wireWindow("local-mac:github-copilot:completions", "Completions", "monthly", 100, 900000, "other:completions")
   + "]}"
  let cpPlatforms = WidgetPresentation.parseSnapshot(data: cpJSON.data(using: .utf8)!, now: now)
  let cp = cpPlatforms.first { $0.providerKey == "github-copilot" || $0.id.contains("copilot") }
  precondition(cp?.windows.count == 3, "copilot buckets collapsed: \(cp?.windows.count ?? -1)")
  print("PASS: wire-level cross-producer merge, MiniMax video identity, Copilot allowance keys")
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
