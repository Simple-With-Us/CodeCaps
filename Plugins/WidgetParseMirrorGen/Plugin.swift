import Foundation
import PackagePlugin

/// Mirrors the iOS widget parse-path sources into the WidgetParseTests target
/// so the wire-parse contract compiles in CI.  The iOS companion is built by
/// xcodebuild, not SPM, so these files sit outside the package's source
/// roots; mirroring them at build time keeps a single source of truth with no
/// committed copy to drift.  (Git symlinks cannot be published through the
/// fleet's hosted write routes, and a 79 KB mirrored file exceeds the hosted
/// blob limit, so build-time mirroring is the publishable shape.)
@main
struct WidgetParseMirrorGenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let packageDir = context.package.directory
        let outputDir = context.pluginWorkDirectory
        let tool = try context.tool(named: "WidgetParseMirrorTool")
        let rels = [
        "ios/CodeCapsCompanion/App/Models/AlarmSoundPlayer.swift",
        "Sources/QuotaCore/AnomalyDetector.swift",
        "Sources/QuotaCore/AntigravityQuotaGroups.swift",
        "Sources/QuotaCore/BoundedHTTPFetch.swift",
        "Sources/QuotaCore/BoundedQuotaProcess.swift",
        "ios/CodeCapsCompanion/App/Models/CompanionQuotaModel.swift",
        "Sources/QuotaCore/CompanionReadTokenStore.swift",
        "ios/CodeCapsCompanion/App/Models/CompanionTheme.swift",
        "Sources/QuotaCore/FleetOrigin.swift",
        "Sources/QuotaCore/FleetSourceDisagreement.swift",
        "Sources/QuotaCore/GrokGrpcCredits.swift",
        "Sources/QuotaCore/InfisicalBinding.swift",
        "Sources/QuotaCore/InfisicalSettings.swift",
        "Sources/QuotaCore/LocalQuotaSnapshot.swift",
        "Sources/QuotaCore/MuseCodeBurnMonitor.swift",
        "Sources/QuotaCore/MuseCodeSessionIngest.swift",
        "Sources/QuotaCore/MuseCodeSessionReader.swift",
        "Sources/QuotaCore/MuseCodeStandardSessionDetector.swift",
        "Sources/QuotaCore/PlaceholderWindows.swift",
        "Sources/QuotaCore/PlanMetadata.swift",
        "Sources/QuotaCore/ProviderUsageDetails.swift",
        "Sources/QuotaCore/QuotaBarMetrics.swift",
        "Sources/QuotaCore/QuotaClient.swift",
        "Sources/QuotaCore/QuotaExhaustionForecast.swift",
        "Sources/QuotaCore/QuotaMeterCadence.swift",
        "Sources/QuotaCore/QuotaModels.swift",
        "Sources/QuotaCore/QuotaPublisher.swift",
        "Sources/QuotaCore/QuotaReaderPreferences.swift",
        "Sources/QuotaCore/QuotaWindowCaption.swift",
        "Sources/QuotaCore/QuotaWindowPairing.swift",
        "Sources/QuotaCore/QuotaWindowPresentation.swift",
        "Sources/QuotaCore/QuotaWindowVocabulary.swift",
        "ios/CodeCapsCompanion/App/Models/RemotePushRegistration.swift",
        "Sources/QuotaCore/ResetAlarmCadence.swift",
        "Sources/QuotaCore/ResetAlarmMessage.swift",
        "Sources/QuotaCore/ResetAlarmSound.swift",
        "Sources/QuotaCore/ResetAlarmTracker.swift",
        "Sources/QuotaCore/SMSAlertCoordinator.swift",
        "Sources/QuotaCore/TokenHygiene.swift",
        "Sources/QuotaCore/TwilioSMSClient.swift",
        "Sources/QuotaCore/UnifiedSubscriptionPool.swift",
        "Sources/QuotaCore/UsageAlertPreferences.swift",
        "Sources/QuotaCore/UsageAlertPublisher.swift",
        "Sources/QuotaCore/UsageMonitorPushMetadata.swift",
        "ios/CodeCapsCompanion/Widgets/WidgetConfigurationIntent.swift",
        "ios/CodeCapsCompanion/Widgets/WidgetDataProvider.swift",
        "ios/CodeCapsCompanion/Widgets/WidgetDetailIntent.swift",
        "Sources/QuotaCore/WidgetPlatformDisplay.swift",
        "ios/CodeCapsCompanion/Widgets/WidgetPresentation.swift",
        "Sources/QuotaCore/WidgetSnapshotFetcher.swift",
        "ios/CodeCapsCompanion/Widgets/WidgetViews.swift",
        "ios/CodeCapsCompanion/Widgets/WidgetWindowRows.swift"
        ]
        let inputs = rels.map { packageDir.appending(subpath: $0) }
        let outputs = rels.map { outputDir.appending(URL(fileURLWithPath: $0).lastPathComponent) }
        return [.buildCommand(
            displayName: "Mirror the iOS widget parse-path sources into WidgetParseTests",
            executable: tool.path,
            arguments: [packageDir.string, outputDir.string] + rels,
            inputFiles: inputs,
            outputFiles: outputs
        )]
    }
}
