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
  // The exact wire capture QA saved from the real feed at 07:49 (committed
  // verbatim at Tests/Fixtures/qa3-wire-regression-fixture.json):  the
  // identities and readings that broke two dedupe designs - the codecaps 5h
  // and the collector weekly share series "general", the collector's 5h is
  // series "minimax:coding-plan", and the video windows share series "video"
  // across cadences.  The parse runs at a fixed "now" just after the capture
  // so freshness and resets stay deterministic.  The contract asserted here:
  // one allowance merges across producers, one model's cadences stay
  // separate, video never folds into plan, Copilot's buckets keep rows.
  let fxNow = ISO8601DateFormatter().date(from: "2026-11-06T07:50:00Z")!
  let fxPath = ProcessInfo.processInfo.environment["WIRE_FIXTURE"] ?? "Tests/Fixtures/qa3-wire-regression-fixture.json"
  guard let fxData = try? Data(contentsOf: URL(fileURLWithPath: fxPath)) else {
   fatalError("wire fixture missing at \(fxPath)")
  }
  let fx = WidgetPresentation.parseSnapshot(data: fxData, now: fxNow)
  let fxm = fx.first { $0.providerKey.contains("minimax") || $0.id.contains("minimax") }
  let fxIds = fxm?.windows.map { $0.id } ?? []
  let phone5h = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"general\"]"
  let macWeekly = "[\"producer\",\"Mac.Jays.Services\",\"general\"]"
  let phoneVideo = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"video\"]"
  let macVideo = "[\"producer\",\"Mac.Jays.Services\",\"video\"]"
  precondition(fxm?.windows.count == 4, "fixture MiniMax should parse to 4 rows (5h plan, 7d plan, 1d video, 7d video): \(fxIds)")
  precondition(fxIds.contains(phone5h), "the fresher codecaps copy should win the merged 5h plan row: \(fxIds)")
  precondition(fxm?.windows.first { $0.id == macWeekly }?.remainingPercent == 5, "the 5% plan weekly must survive")
  precondition(fxIds.contains(phoneVideo) && fxIds.contains(macVideo), "both video cadences keep rows: \(fxIds)")
  precondition(fxm?.windows.filter { $0.isSupplementaryVideoQuota }.count == 2, "both video rows flagged")
  precondition(fxm?.windows.filter { !$0.isSupplementaryVideoQuota }.count == 2, "exactly the two plan rows unflagged")
  precondition(fxm?.dualWindows()?.window1.id == phone5h, "the pair must open on the plan 5h")
  precondition(fxm?.dualWindows()?.window2.id == macWeekly, "the pair must hold the plan weekly, never a video row")
  let fxc = fx.first { $0.providerKey.contains("copilot") || $0.id.contains("copilot") }
  precondition(fxc?.windows.count == 3, "copilot buckets collapsed: \(fxc?.windows.count ?? -1)")
  precondition(fxc?.windows.contains { $0.remainingPercent == 0 } == true, "the exhausted Premium row must stay visible")
  print("PASS: real wire fixture - MiniMax 4 rows, pair 5h+weekly plan, video separate, Copilot 3")
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
