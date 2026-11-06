import SwiftUI
import AppKit
import WidgetKit
import AppIntents

// QA6 diagnostic harness (uncommitted): wire-level discriminating cases for the
// PR #369 video cap-state exclusion, through the real parseSnapshot path, plus
// rendered pixels of each scenario. Runs against the unmodified committed head.
@main struct QA6CapProbe {
 @MainActor static func main() async throws {
  let fxNow = ISO8601DateFormatter().date(from: "2026-11-06T10:30:00Z")!
  let renderDir = ProcessInfo.processInfo.environment["CODECAPS_WIDGET_RENDER_DIR"] ?? NSTemporaryDirectory()
  func load(_ path: String) -> [WidgetPlatformItem] {
   guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { fatalError("missing fixture \(path)") }
   return WidgetPresentation.parseSnapshot(data: data, now: fxNow)
  }
  let phone5h = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"general\"]"
  let phoneVideo = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"video\"]"

  // A: spent video (0%, exhausted) beside live plan windows (78% 5h, 5% 7d)
  let pa = load("qa6-harness/qa6-a-spent-video-live-plan.json").first { $0.providerKey == "minimax" }!
  precondition(pa.windows.count == 4, "A: expected 4 rows, got \(pa.windows.map { $0.id })")
  precondition(pa.windows.filter { $0.isSupplementaryVideoQuota }.count == 2, "A: both video rows flagged")
  precondition(pa.atCapWindow(now: fxNow) == nil, "A: spent video must NOT cap a live plan via wire path")
  precondition(pa.remainingPercent == 5, "A: headline must derive from plan windows (5), not the spent video (0); got \(String(describing: pa.remainingPercent))")
  precondition(pa.isExhausted == false, "A: platform must not read exhausted")
  precondition(pa.dualWindows()?.window1.id == phone5h, "A: pair opens on plan 5h")
  print("PASS A: wire spent-video/live-plan - no cap, headline 5%, pair 5h+7d")

  // B: spent plan 5h (0%, exhausted) beside live video (100%)
  let pb = load("qa6-harness/qa6-b-spent-plan-live-video.json").first { $0.providerKey == "minimax" }!
  precondition(pb.windows.count == 4, "B: expected 4 rows, got \(pb.windows.map { $0.id })")
  precondition(pb.atCapWindow(now: fxNow)?.id == phone5h, "B: the spent plan 5h must cap the platform; got \(String(describing: pb.atCapWindow(now: fxNow)?.id))")
  precondition(pb.isExhausted == true, "B: platform reads exhausted")
  print("PASS B: wire spent-plan/live-video - plan 5h caps the platform")

  // C: video-only platform, its one video spent -> all-window fallback keeps the video cap
  let pc = load("qa6-harness/qa6-c-video-only-spent.json").first { $0.providerKey == "minimax" }!
  precondition(pc.windows.count == 1, "C: expected 1 row, got \(pc.windows.map { $0.id })")
  precondition(pc.windows.first?.isSupplementaryVideoQuota == true, "C: the row is flagged video")
  precondition(pc.atCapWindow(now: fxNow)?.id == phoneVideo, "C: video-only fallback binds the video window; got \(String(describing: pc.atCapWindow(now: fxNow)?.id))")
  precondition(pc.isExhausted == true, "C: platform reads exhausted")
  print("PASS C: wire video-only spent - fallback keeps the video cap")

  // Pixel proof: render the actual widget views per scenario (single-platform
  // entries - the three parsed platforms share id/providerKey "minimax", so a
  // combined ForEach would collapse them onto the first).
  let scenarios: [(String, WidgetPlatformItem)] = [("a-spent-video-live-plan", pa), ("b-spent-plan-live-video", pb), ("c-video-only-spent", pc)]
  for (sname, platform) in scenarios {
   let solo = CodeCapsWidgetEntry(date: fxNow, platforms: [platform], lastUpdated: fxNow)
   for (schemeName, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
    let focus = ProviderFocusView(entry: solo)
     .frame(width: 364, height: 170)
     .padding(8).background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme, scheme)
    let r1 = ImageRenderer(content: focus); r1.scale = 2
    guard let img1 = r1.cgImage else { fatalError("render unavailable") }
    try NSBitmapImageRep(cgImage: img1).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(renderDir)/qa6-\(sname)-focus-medium-\(schemeName).png"))
    let detail = WidgetPlanDetailView(platform: platform, entry: solo).padding(14).frame(width: 338, height: 354)
     .padding(8).background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme, scheme)
    let r2 = ImageRenderer(content: detail); r2.scale = 2
    guard let img2 = r2.cgImage else { fatalError("render unavailable") }
    try NSBitmapImageRep(cgImage: img2).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(renderDir)/qa6-\(sname)-detail-\(schemeName).png"))
   }
  }
  print("PASS render: qa6 scenario pixels written to \(renderDir)")
 }
}
