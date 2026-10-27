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
   WidgetWindowItem(id:"extra",label:"Extra balance",cadence:"Other limit",remainingPercent:83,resetAt:nil,isExtraAllowance:true)
  ])]
  let edgePlatforms = platforms
  platforms += WidgetPresentation.placeholders
  platforms.append(WidgetPlatformItem(id:"overflow",providerKey:"codex",title:"Overflow plan",subtitle:"",remainingPercent:50,resetAt:nil,windows:[]))
  precondition(edgePlatforms[1].usableMuseExtra?.remainingPercent == 83)
  precondition(edgePlatforms[1].atCapWindow()?.remainingPercent == 0)
  precondition(platforms[1].usableMuseExtra?.remainingPercent == 83)
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
