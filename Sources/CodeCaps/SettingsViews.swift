import AppKit
import QuotaCore
import SwiftUI

/// Shared chrome for a settings page.  Every page is a `Form` with no fixed
/// height, inside the Console's own `ScrollView`, so the 580x510-versus-620x560
/// clipping bug cannot recur anywhere.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .padding(.vertical, 4)
    }
}

// MARK: - Menu Bar

struct SettingsMenuBarPage: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        SettingsPage {
            Section {
                Picker("Show In", selection: $model.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Both keeps the menu bar icon and a Dock icon." + sentenceGap
                     + "Dock hides the menu bar icon, so use Open CodeCaps to reach your quota.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Style", selection: $model.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Displayed Quota", selection: $model.menuBarQuotaSelection) {
                    Section("Automatic (Fleet-Wide)") {
                        ForEach(model.menuBarAutomaticOptions, id: \.id) { item in
                            Text(item.label).tag(item.id)
                        }
                    }
                    if !model.menuBarPlatformPairOptions.isEmpty {
                        Section("Pin to Platform (Both Quotas)") {
                            ForEach(model.menuBarPlatformPairOptions, id: \.id) { item in
                                Text(item.label).tag(item.id)
                            }
                        }
                    }
                    Section("Pin to Platform (Lowest Quota)") {
                        ForEach(model.menuBarPlatformSingleOptions, id: \.id) { item in
                            Text(item.label).tag(item.id)
                        }
                    }
                    Section("Specific Quota Window") {
                        ForEach(model.menuBarIndividualWindowOptions, id: \.id) { item in
                            Text(item.label).tag(item.id)
                        }
                    }
                    if !model.menuBarAutomaticOptions.contains(where: { $0.id == model.menuBarQuotaSelection })
                        && !model.menuBarPlatformPairOptions.contains(where: { $0.id == model.menuBarQuotaSelection })
                        && !model.menuBarPlatformSingleOptions.contains(where: { $0.id == model.menuBarQuotaSelection })
                        && !model.menuBarIndividualWindowOptions.contains(where: { $0.id == model.menuBarQuotaSelection }) {
                        Text("Pinned quota unavailable").tag(model.menuBarQuotaSelection)
                    }
                }

                Text(model.menuBarQuotaDescription(for: model.menuBarQuotaSelection))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Menu Bar Mark", selection: $model.menuBarMarkStyle) {
                    ForEach(MenuBarMarkStyle.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Eyebrow("MENU BAR")
            } footer: {
                Text("Match Provider follows each platform's Logo Style." + sentenceGap
                     + "Light/Dark and Colour override it for the menu bar only, leaving the Docked Bar and sidebar on whatever you set on Logo Style.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Preview") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if model.menuBarStyle != .percentOnly {
                                let previewKey = model.menuBarTargetSnapshot?.window.canonicalProviderKey ?? "auto"
                                PlatformLogo(providerKey: previewKey,
                                             size: 14,
                                             style: model.markStyle(for: previewKey))
                            }
                            if model.menuBarStyle != .symbolOnly {
                                Text(model.menuBarTitle.isEmpty ? "—" : model.menuBarTitle)
                                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                            }
                        }
                        Text(model.menuBarDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Menu Bar Preview")
                }
            }

            Section {
                Toggle("Floating On-Screen PiP Widget", isOn: $model.isPipEnabled)
                    .help("Keep selected quotas in a compact floating HUD widget on top of all windows.")
                    .accessibilityLabel("Floating On-Screen PiP Widget")

                if model.isPipEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pinned Quotas (Default: Lowest 2 Remaining)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(model.displaySections) { row in
                            Toggle(row.title, isOn: Binding(
                                get: { model.pipPinnedRowIds.contains(row.id) },
                                set: { checked in
                                    if checked {
                                        model.pipPinnedRowIds.insert(row.id)
                                    } else {
                                        model.pipPinnedRowIds.remove(row.id)
                                    }
                                }
                            ))
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Eyebrow("PICTURE IN PICTURE (PIP)")
            } footer: {
                Text("A tiny on-screen HUD stays on top of all windows so you are aware of critical quotas in real time.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Platforms

struct SettingsPlatformsPage: View {
    @ObservedObject var model: MonitorModel
    @State private var selection: String?

    private var orderedKeys: [String] {
        let live = model.sections.map(\.providerKey)
        guard !model.platformOrder.isEmpty else { return live }
        let ordered = model.platformOrder.filter(live.contains)
        return ordered + live.filter { !ordered.contains($0) }
    }

    private func label(for providerKey: String) -> String {
        model.sections.first { $0.providerKey == providerKey }?.providerLabel ?? providerKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag to reorder." + sentenceGap
                 + "This order is used in the quota list and in the Docked Bar.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A plain List outside a Form group, because `.onMove`'s drop
            // indicator misbehaves inside `.formStyle(.grouped)`.
            List(selection: $selection) {
                ForEach(orderedKeys, id: \.self) { providerKey in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .help("Drag to Reorder")
                            .accessibilityHidden(true)
                        PlatformLogo(providerKey: providerKey, size: 16,
                                     style: model.markStyle(for: providerKey))
                        Text(label(for: providerKey)).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .tag(providerKey)
                    .accessibilityLabel("\(label(for: providerKey)), position \((orderedKeys.firstIndex(of: providerKey) ?? 0) + 1) of \(orderedKeys.count)")
                }
                .onMove(perform: move)
            }
            .listStyle(.inset)
            // One expression, because a `minHeight` of 240 above a `maxHeight`
            // of 226 (seven platforms) clipped the last row by 14pt.
            .frame(height: max(240, CGFloat(orderedKeys.count) * 30 + 16))

            HStack {
                Spacer()
                Button("Reset Default Order") { model.resetPlatformOrder() }
                    .help("Reset Default Order")
                    .accessibilityLabel("Reset Default Order")
            }
        }
        .padding(Metrics.pagePadding)
        .background {
            // Keyboard equivalents for the drag the chevrons used to stand in for.
            VStack {
                Button("") { moveSelection(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                Button("") { moveSelection(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var keys = orderedKeys
        keys.move(fromOffsets: source, toOffset: destination)
        model.platformOrder = keys
    }

    private func moveSelection(by delta: Int) {
        guard let selection else { return }
        if delta < 0 { model.movePlatformUp(providerKey: selection) }
        else { model.movePlatformDown(providerKey: selection) }
    }
}

// MARK: - Sources & Fleet

struct SettingsSourcesFleetPage: View {
    @ObservedObject var model: MonitorModel

    @State private var syncEndpoint = ""
    @State private var syncToken = ""
    @State private var syncFormat: QuotaSyncFormat = .usageMonitorV2
    @State private var pushing = false
    @State private var pushMessage: String?
    @State private var pushSucceeded = false

    @State private var pullEndpoint = ""
    @State private var pullToken = ""
    /// Draft on/off state for the two fleet groups.  Turning a group on only
    /// unlocks its fields; the setting itself is committed by the group's
    /// Save button, so an empty endpoint can never deadlock the toggle.
    @State private var pushEnabled = false
    @State private var pullEnabled = false
    @State private var pulling = false
    @State private var reauthorizingPush = false
    @State private var reauthorizingPull = false
    @State private var pullMessage: String?
    @State private var pullSucceeded = false
    @State private var allowingClaude = false
    @State private var claudeConsentMessage: String?
    @State private var claudeConsentSucceeded = false

    private var pushDirty: Bool {
        pushEnabled != model.syncEnabled || syncEndpoint != model.syncEndpoint || syncFormat != model.syncFormat || !syncToken.isEmpty
    }
    private var pullDirty: Bool {
        pullEnabled != model.serverEnabled || pullEndpoint != model.endpoint || !pullToken.isEmpty
    }

    private var dashboardURL: URL? {
        guard let url = URL(string: model.endpoint),
              let scheme = url.scheme, let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }

    var body: some View {
        SettingsPage {
            Section {
                Link("Setup & Data Guide", destination: URL(string: "https://codecaps.simplewithus.com/setup.html")!)
                Text("Choose local reading, uploads, and downloads independently.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            thisMacSection
            sourcesRankSection
            shareSection
            pullSection
        }
        .onAppear {
            syncEndpoint = model.syncEndpoint
            syncFormat = model.syncFormat
            pullEndpoint = model.endpoint
            pushEnabled = model.syncEnabled
            pullEnabled = model.serverEnabled
        }
        .task { await model.refreshSavedTokenStates() }
        .onChange(of: model.syncEnabled) { _, newValue in pushEnabled = newValue }
        .onChange(of: model.serverEnabled) { _, newValue in pullEnabled = newValue }
    }

    // MARK: This Mac

    private var thisMacSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Machine Identity: \(QuotaPublisher.machineName)")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Host: \(ProcessInfo.processInfo.hostName)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Identified")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 2)

            Toggle("Read Quotas From This Mac",
                   isOn: Binding(get: { model.localEnabled }, set: { model.setLocalEnabled($0) }))
            Toggle("Provider Checks", isOn: Binding(
                get: { model.providerChecksEnabled }, set: { model.setProviderChecksEnabled($0) }))
                .disabled(!model.localEnabled)
            Picker("Provider Check Interval", selection: $model.providerCheckCadence) {
                ForEach(SourceRefreshCadence.allCases) { cadence in
                    Text(cadence.title).tag(cadence)
                }
            }
            .disabled(!model.localEnabled || !model.providerChecksEnabled)
            Toggle("Codex Session File Checks", isOn: Binding(
                get: { model.sessionFileChecksEnabled }, set: { model.setSessionFileChecksEnabled($0) }))
                .disabled(!model.localEnabled)
            Picker("Session File Check Interval", selection: $model.sessionFileCadence) {
                ForEach(SourceRefreshCadence.allCases) { cadence in
                    Text(cadence.title).tag(cadence)
                }
            }
            .disabled(!model.localEnabled || !model.sessionFileChecksEnabled)
            ForEach(ReaderStatus.all, id: \.providerKey) { reader in
                readerRow(reader)
            }
        } header: {
            Eyebrow("THIS MAC")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("CodeCaps reads each CLI's own saved credentials in place." + sentenceGap
                     + "It never asks you for a provider API key.")
                Text("Provider Checks: 7 HTTP paths and 3 local helpers across 8 AI plan families." + sentenceGap
                     + "These are source capabilities, not a request count per check.")
                Text("Codex Session File Checks: 1 local quota source." + sentenceGap
                     + "File checks do not upload or download on their own.")
                Text("A snapshot is written to ~/Library/Application Support/Usage Monitor/quota-windows.json for BotFleet.")
                if let widgetSharingError = model.widgetSharingError {
                    Text(widgetSharingError).foregroundStyle(Theme.warning)
                }
                if let handoffError = model.handoffError {
                    Text(handoffError).foregroundStyle(Theme.warning)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readerRow(_ reader: ReaderStatus) -> some View {
        let section = model.sections.first { $0.providerKey == reader.providerKey }
        let issue = model.issues[reader.providerKey]
        let healthy = issue == nil && !(section?.windows.isEmpty ?? true)
        // A reader whose credential is on this Mac but unreadable by this
        // build gets a button rather than a sentence it cannot act on.
        let needsConsent = model.consentNeeded.contains(reader.providerKey)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                PlatformLogo(providerKey: reader.providerKey, size: 16,
                             style: model.markStyle(for: reader.providerKey))
                Text(section?.providerLabel ?? reader.label)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 110, alignment: .leading)
                Text(reader.source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Image(systemName: healthy ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(healthy ? Theme.accent : Theme.warning)
                    .accessibilityHidden(true)
            }
            if let issue {
                Text(issue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !healthy && model.localEnabled {
                Text("Not signed in locally.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if needsConsent { claudeConsentControls }
        }
        // A row carrying a button must stay navigable, so only the plain rows
        // collapse into one element.
        .accessibilityElement(children: needsConsent ? .contain : .combine)
    }

    /// The consent step, shown only when macOS explicitly refuses the
    /// `security` read the refresh loop makes.  The button runs that same
    /// `security` read without a short deadline, so the panel macOS shows, and
    /// the Always Allow answered in it, apply to the program the loop reads as.
    @ViewBuilder
    private var claudeConsentControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button("Allow Access To Claude Code") {
                    allowingClaude = true
                    claudeConsentMessage = nil
                    Task {
                        defer { allowingClaude = false }
                        let (ok, message) = await model.allowClaudeCodeAccess()
                        claudeConsentSucceeded = ok
                        claudeConsentMessage = message
                    }
                }
                .disabled(allowingClaude)
                .help("Allow Access To Claude Code")
                .accessibilityLabel("Allow Access To Claude Code")
                .accessibilityHint("Asks macOS once for permission to read Claude Code's saved login.")
                if allowingClaude {
                    ProgressView().controlSize(.small)
                }
            }
            Text("macOS will ask once." + sentenceGap + "Choose Always Allow.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let claudeConsentMessage {
                Text(claudeConsentMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(claudeConsentSucceeded ? Theme.accent : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Source Ranking

    /// Per-provider source enable + rank.  Sections only render for providers
    /// that have more than one observed source — the Settings page should not
    /// tease a control that has no effect.
    @ViewBuilder
    private var sourcesRankSection: some View {
        let grouped: [(key: String, label: String, sources: [String])] = model.displaySections
            .map(\.section.providerKey)
            .reduce(into: [String]()) { acc, key in
                let sources = model.availableSources(for: key)
                guard sources.count > 1 else { return }
                if !acc.contains(key) { acc.append(key) }
            }
            .map { key in
                let label = model.sections.first { $0.providerKey == key }?.providerLabel ?? key
                return (key: key, label: label, sources: model.availableSources(for: key))
            }
        if !grouped.isEmpty {
            Section {
                ForEach(grouped, id: \.key) { group in
                    sourceGroup(for: group.key, label: group.label, sources: group.sources)
                }
            } header: {
                Eyebrow("SOURCES PER PLATFORM")
            } footer: {
                Text("CodeCaps pulls each provider's quota from whichever sources can answer." + sentenceGap
                     + "Turn a source off to drop its windows everywhere — the menu bar, Docked Bar, and Console all skip it." + sentenceGap
                     + "Reorder to tell CodeCaps which source wins when two disagree; the top of the list is preferred, the bottom is the fallback.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func sourceGroup(for providerKey: String, label: String, sources: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // This one shipped without a `style:`, so it drew the init's
                // old default of `.template` and every mark here came out grey
                // no matter what the Logo Style page had set.  The init no
                // longer has a default for exactly this reason.
                PlatformLogo(providerKey: providerKey, size: 16,
                             style: model.markStyle(for: providerKey))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(sources.count) sources")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                sourceRow(source: source,
                          index: index,
                          total: sources.count,
                          providerKey: providerKey)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sourceRow(source: String, index: Int, total: Int, providerKey: String) -> some View {
        let enabled = !model.disabledSources.contains(source)
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { model.setSourceEnabled($0, source, for: providerKey) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(enabled ? "Hide windows from \(source)" : "Show windows from \(source)")
                .accessibilityLabel(enabled ? "Hide windows from \(source)" : "Show windows from \(source)")

            Text(source)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(enabled ? Theme.ink : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("#\(index + 1)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)

            Button {
                model.moveSource(source, by: -1, for: providerKey)
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move \(source) up")
            .accessibilityLabel("Move \(source) up")

            Button {
                model.moveSource(source, by: 1, for: providerKey)
            } label: {
                Image(systemName: "arrow.down").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(index == total - 1)
            .help("Move \(source) down")
            .accessibilityLabel("Move \(source) down")
        }
        .padding(.leading, 24)
    }


/// Shown under a group's header when a token is on file that this build cannot
/// read.  Plain words, because the alternative the owner actually met was a
/// pull that failed with nothing to act on.
private struct ReauthorizeCaption: View {
    var body: some View {
        Text("This build cannot read the saved token yet." + sentenceGap
             + "Re-authorize it, or paste the token again.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.warning)
            .textCase(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}

    // MARK: Share This Mac

    private var shareSection: some View {
        Section {
            Toggle("Push Quotas to a Server", isOn: Binding(
                get: { pushEnabled },
                set: { newValue in
                    pushEnabled = newValue
                    if !newValue { model.disableSync() }
                }))
            TextField("Ingest Endpoint", text: $syncEndpoint,
                      prompt: Text("https://usage.example.com/api/ingest/usage"))
                .disabled(!pushEnabled)
                .onSubmit(savePush)
            SecureField("Ingest Token", text: $syncToken,
                        prompt: Text(model.hasSavedSyncToken ? "Saved in Keychain" : "Ingest Token"))
                .disabled(!pushEnabled)
                .onSubmit(savePush)
            Picker("Payload Format", selection: $syncFormat) {
                ForEach(QuotaSyncFormat.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!pushEnabled)

            if pushDirty {
                Text("Unsaved changes").font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            HStack(spacing: 10) {
                if model.syncTokenState.needsReauthorization {
                    Button("Re-Authorize Saved Token") {
                        reauthorizingPush = true
                        pushMessage = nil
                        Task {
                            defer { reauthorizingPush = false }
                            let (ok, message) = await model.reauthorizeSyncToken()
                            pushSucceeded = ok
                            pushMessage = message
                        }
                    }
                    .disabled(reauthorizingPush)
                    .help("Re-Authorize Saved Token")
                    .accessibilityLabel("Re-Authorize Saved Token")
                }
                if model.hasSavedSyncToken {
                    Button("Forget Ingest Token", role: .destructive) {
                        Task {
                            do {
                                try await model.forgetSyncServer()
                                syncToken = ""
                                pushSucceeded = true
                                pushMessage = "Ingest token removed."
                            } catch {
                                pushSucceeded = false
                                pushMessage = error.localizedDescription
                            }
                        }
                    }
                    .help("Forget Ingest Token")
                    .accessibilityLabel("Forget Ingest Token")
                }
                Spacer()
                if pushing { ProgressView().controlSize(.small) }
                CommitButton(title: "Save & Push Now", prominent: pushDirty, action: savePush)
                    .disabled(!pushEnabled || pushing)
            }
            if let pushMessage {
                Text(pushMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(pushSucceeded ? Theme.accent : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Eyebrow("SHARE THIS MAC")
                    Spacer()
                    Text(model.lastSyncTime.map { "Pushed \($0.formatted(date: .omitted, time: .shortened))" } ?? "Never pushed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                // The last push failure lives with the group that owns it, so a
                // token the server rejects is visible without pressing anything.
                if model.syncTokenState.needsReauthorization {
                    ReauthorizeCaption()
                }
                if let pushError = model.lastSyncError {
                    Text("Last push failed." + sentenceGap + pushError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Text("The Ingest Token is stored in your Keychain, never in a preference file.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func savePush() {
        pushing = true
        pushMessage = nil
        Task {
            defer { pushing = false }
            do {
                try await model.saveSyncSettings(enabled: pushEnabled,
                                                 endpoint: syncEndpoint,
                                                 token: syncToken,
                                                 format: syncFormat)
                let (ok, message) = await model.testAndPushSync(endpoint: syncEndpoint,
                                                                token: syncToken,
                                                                format: syncFormat)
                syncToken = ""
                pushSucceeded = ok
                pushMessage = message
            } catch {
                pushSucceeded = false
                pushMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Pull The Fleet

    private var pullSection: some View {
        Section {
            Toggle("Show Other Machines' Quotas", isOn: Binding(
                get: { pullEnabled },
                set: { newValue in
                    pullEnabled = newValue
                    if !newValue { model.disableServerPull() }
                }))
            TextField("Quota Endpoint", text: $pullEndpoint,
                      prompt: Text("https://usage.example.com/api/quota-windows"))
                .disabled(!pullEnabled)
                .onSubmit(savePull)
            SecureField("Read Token", text: $pullToken,
                        prompt: Text(model.hasSavedToken ? "Saved in Keychain" : "Read Token"))
                .disabled(!pullEnabled)
                .onSubmit(savePull)

            if pullDirty {
                Text("Unsaved changes").font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            HStack(spacing: 10) {
                if model.readTokenState.needsReauthorization {
                    Button("Re-Authorize Saved Token") {
                        reauthorizingPull = true
                        pullMessage = nil
                        Task {
                            defer { reauthorizingPull = false }
                            let (ok, message) = await model.reauthorizeReadToken()
                            pullSucceeded = ok
                            pullMessage = message
                        }
                    }
                    .disabled(reauthorizingPull)
                    .help("Re-Authorize Saved Token")
                    .accessibilityLabel("Re-Authorize Saved Token")
                }
                if model.hasSavedToken {
                    Button("Forget Read Token", role: .destructive) {
                        Task {
                            do {
                                try await model.forgetServer()
                                pullToken = ""
                                pullSucceeded = true
                                pullMessage = "Read token removed."
                            } catch {
                                pullSucceeded = false
                                pullMessage = error.localizedDescription
                            }
                        }
                    }
                    .help("Forget Read Token")
                    .accessibilityLabel("Forget Read Token")
                }
                Spacer()
                if pulling { ProgressView().controlSize(.small) }
                CommitButton(title: "Save & Fetch Now", prominent: pullDirty, action: savePull)
                    .disabled(!pullEnabled || pulling)
            }
            if let pullMessage {
                Text(pullMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(pullSucceeded ? Theme.accent : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
            HStack {
                Eyebrow("PULL THE FLEET")
                Spacer()
                if let dashboardURL {
                    Button {
                        NSWorkspace.shared.open(dashboardURL)
                    } label: {
                        Label("Open Web Dashboard", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .textCase(nil)
                    .help("Open Web Dashboard")
                    .accessibilityLabel("Open Web Dashboard")
                }
                Text(model.lastPullTime.map { "Pulled \($0.formatted(date: .omitted, time: .shortened))" } ?? "Never pulled")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
                if model.readTokenState.needsReauthorization {
                    ReauthorizeCaption()
                }
                if let pullError = model.serverError {
                    Text("Last pull failed." + sentenceGap + pullError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Text("Refreshes every 5 minutes while CodeCaps is running.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func savePull() {
        pulling = true
        pullMessage = nil
        Task {
            defer { pulling = false }
            do {
                try await model.saveConnection(local: model.localEnabled,
                                               server: pullEnabled,
                                               endpoint: pullEndpoint,
                                               token: pullToken)
                let (ok, message) = await model.testPullConnection(endpoint: pullEndpoint, token: pullToken)
                pullToken = ""
                pullSucceeded = ok
                pullMessage = message
            } catch {
                pullSucceeded = false
                pullMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// The seven local readers, named by the credential they actually read.
struct ReaderStatus {
    let providerKey: String
    let label: String
    let source: String

    static let all: [ReaderStatus] = [
        ReaderStatus(providerKey: "anthropic", label: "Claude", source: "Claude Code credentials"),
        ReaderStatus(providerKey: "openai", label: "Codex", source: "Codex CLI credentials"),
        ReaderStatus(providerKey: "google-antigravity", label: "Antigravity", source: "Antigravity app or CLI"),
        ReaderStatus(providerKey: "cursor", label: "Cursor", source: "Cursor app session"),
        ReaderStatus(providerKey: "xai", label: "Grok", source: "Grok CLI credentials"),
        ReaderStatus(providerKey: "grok-bot", label: "Grok Bot", source: "Cursor app session"),
        ReaderStatus(providerKey: "minimax", label: "MiniMax", source: "MiniMax CLI credentials"),
    ]
}

// MARK: - Appearance

/// The accent swatches.  A swatch shows the colour rather than naming it,
/// because the choice is "which colour" and a list of six names is six rows of
/// something the owner has to read to find the one they want.
private struct AccentPicker: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Accent")
                .font(.system(size: 12))
            ForEach(AccentChoice.allCases) { choice in
                Circle()
                    .fill(Color(nsColor: NSColor(name: nil) {
                        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                            ? NSColor(srgbRed: CGFloat((choice.darkHex >> 16) & 0xFF) / 255,
                                      green: CGFloat((choice.darkHex >> 8) & 0xFF) / 255,
                                      blue: CGFloat(choice.darkHex & 0xFF) / 255, alpha: 1)
                            : NSColor(srgbRed: CGFloat((choice.lightHex >> 16) & 0xFF) / 255,
                                      green: CGFloat((choice.lightHex >> 8) & 0xFF) / 255,
                                      blue: CGFloat(choice.lightHex & 0xFF) / 255, alpha: 1)
                    }))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle().strokeBorder(.primary.opacity(model.accent == choice ? 1 : 0),
                                              lineWidth: model.accent == choice ? 2 : 0)
                    )
                    .contentShape(Circle())
                    .onTapGesture { model.accent = choice }
                    .help(choice.title)
                    .accessibilityLabel(choice.title)
                    .accessibilityAddTraits(model.accent == choice ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct SettingsAppearancePage: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        SettingsPage {
            Section {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Theme")
                .accessibilityLabel("Theme")

                AccentPicker(model: model)

                Toggle("High Contrast", isOn: $model.highContrast)
                    .help("Stronger surfaces, borders and greys, for a display where the soft defaults fall together.")
                    .accessibilityLabel("High Contrast")

                Toggle("Dynamic Pacing Highlights", isOn: $model.pacingColorHighlights)
                    .help("Tints percentage pills greener when under cap pace and redder when burning quota faster than time elapsed.")
                    .accessibilityLabel("Dynamic Pacing Highlights")
            } footer: {
                Text("System is the default." + sentenceGap + "Light and Dark ignore your Mac's setting." + sentenceGap
                     + "Dynamic Pacing Highlights variably tints percentage pills greener when under cap pace and redder when burning quota faster than elapsed time.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Logo Style

struct SettingsLogoStylePage: View {
    @ObservedObject var model: MonitorModel

    private var orderedKeys: [String] {
        if model.displaySections.isEmpty {
            return ["claude", "cursor", "codex", "gemini", "antigravity", "grok", "grok-bot", "minimax"]
        }
        let live = Set(model.displaySections.map(\.id))
        let stored = model.platformOrder.filter(live.contains)
        let unsorted = live.filter { !stored.contains($0) }.sorted()
        let canonical = model.displaySections.map(\.id)
        let orderedUnsorted = unsorted.sorted {
            let left = canonical.firstIndex(of: $0) ?? 0
            let right = canonical.firstIndex(of: $1) ?? 0
            return left < right
        }
        return stored + orderedUnsorted
    }

    private func label(for rowId: String) -> String {
        if let match = model.displaySections.first(where: { $0.id == rowId }) {
            return match.title
        }
        switch rowId {
        case "claude", "anthropic": return "Claude Code"
        case "cursor": return "Cursor"
        case "codex", "openai": return "Codex"
        case "gemini": return "Gemini"
        case "antigravity", "google-antigravity": return "Antigravity"
        case "grok", "xai": return "Grok"
        case "grok-bot": return "Grok Bot"
        case "minimax": return "MiniMax"
        default: return rowId.capitalized
        }
    }

    var body: some View {
        SettingsPage {
            Section {
                ForEach(orderedKeys, id: \.self) { providerKey in
                    row(for: providerKey)
                }
            } header: {
                Eyebrow("PROVIDER MARKS")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Standard keeps the brand colors." + sentenceGap
                         + "Light/Dark shows a single silhouette that picks up the surface color, which reads on any menu bar tint." + sentenceGap
                         + "Custom replaces the bundled mark with a file you choose.")
                    Text("For custom marks, choose Color Version to preserve full-color artwork or Light/Dark Version for adaptive monochrome." + sentenceGap
                         + "An optional dark appearance variant can also be supplied.")
                    Text("Custom files are stored in ~/Library/Application Support/CodeCaps/CustomMarks/.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func row(for providerKey: String) -> some View {
        let style = model.markStyle(for: providerKey)
        let customURL = model.customMarkURL(for: providerKey, isDarkMode: false)
        let customDarkURL = model.customMarkURL(for: providerKey, isDarkMode: true)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                PlatformLogo(providerKey: providerKey, size: 18, style: style)
                Text(label(for: providerKey))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("", selection: Binding(
                    get: { model.markStyle(for: providerKey) },
                    set: { model.setMarkStyle($0, for: providerKey) })) {
                    ForEach(MarkStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
                .help("Logo Style for \(label(for: providerKey))")
                .accessibilityLabel("Logo Style for \(label(for: providerKey))")
            }
            // Say it rather than let it look broken.  Codex, Cursor, Grok, Grok
            // Bot and MiniMax ship as single-colour marks, and the app renders
            // them as templates in every style so they never draw black on a
            // dark surface.  Choosing Standard for one of them therefore
            // changes nothing visible, which reads as the setting being broken
            // rather than as the artwork having no colour to keep.
            if style != .custom, PlatformLogoImage.isMonochromeMark(providerKey) {
                Text("Single-colour mark." + sentenceGap
                     + "Standard and Light/Dark look the same here, because this artwork has no brand colour to preserve.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if style == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Custom Logo Mode", selection: Binding(
                        get: { model.customMarkMode(for: providerKey) },
                        set: { model.setCustomMarkMode($0, for: providerKey) })) {
                        ForEach(CustomMarkMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)

                    HStack(spacing: 8) {
                        Text(customDarkURL == nil ? "Image:" : "Light Appearance:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 105, alignment: .leading)
                        Button(customURL == nil ? "Choose File…" : "Replace…") {
                            pickCustom(for: providerKey, isDarkMode: false)
                        }
                        .buttonStyle(.bordered)
                        if let customURL {
                            Text(customURL.lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Show In Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([customURL])
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            Button("Remove", role: .destructive) {
                                model.clearCustomMark(for: providerKey, isDarkMode: false)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }
                    }

                    HStack(spacing: 8) {
                        Text("Dark Appearance:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 105, alignment: .leading)
                        Button(customDarkURL == nil ? "Choose File (Optional)…" : "Replace Dark…") {
                            pickCustom(for: providerKey, isDarkMode: true)
                        }
                        .buttonStyle(.bordered)
                        if let customDarkURL {
                            Text(customDarkURL.lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Show In Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([customDarkURL])
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            Button("Remove", role: .destructive) {
                                model.clearCustomMark(for: providerKey, isDarkMode: true)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 2)
    }

    private func pickCustom(for providerKey: String, isDarkMode: Bool = false) {
        let panel = NSOpenPanel()
        let appearanceName = isDarkMode ? " (Dark Appearance)" : ""
        panel.title = "Choose a Mark for \(label(for: providerKey))\(appearanceName)"
        panel.allowedContentTypes = [.svg, .png, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            _ = model.setCustomMark(at: url, for: providerKey, isDarkMode: isDarkMode)
        }
    }
}

// MARK: - About

struct SettingsAboutPage: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState
    @ObservedObject private var updater = AppUpdater.shared

    private static let projectPage = URL(string: "https://github.com/Simple-With-Us/codecaps")!

    private var pushingDetail: String {
        guard model.syncEnabled else { return "Off" }
        guard let host = URL(string: model.syncEndpoint)?.host() else { return "On" }
        return "On · \(host)"
    }
    private var pullingDetail: String {
        guard model.serverEnabled else { return "Off" }
        guard let host = URL(string: model.endpoint)?.host() else { return "On" }
        return "On · \(host)"
    }

    var body: some View {
        SettingsPage {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("CodeCaps").font(.system(size: 16, weight: .semibold))
                    Text(CodeCapsVersion.display)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                LabeledContent("Pushing quota") { Text(pushingDetail) }
                LabeledContent("Pulling quota") { Text(pullingDetail) }
                LabeledContent("Local readers") { Text(model.localEnabled ? "On" : "Off") }
            }

            Section {
                LabeledContent("Automatic updates") { Text(updater.availability.summary) }
                Button("Check For Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                    .help("Check For Updates")
                    .accessibilityLabel("Check For Updates")
            } footer: {
                Text(updater.availability.isEnabled
                     ? "CodeCaps checks for a new signed release every hour and installs it in the background." + sentenceGap
                        + "If CodeCaps is in front when an update is ready, it waits until you switch away."
                     : "Development builds do not update themselves." + sentenceGap
                        + "Install a release from the project page to get automatic updates.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button {
                    NSWorkspace.shared.open(Self.projectPage)
                } label: {
                    Label("Project Page", systemImage: "arrow.up.right.square")
                }
                .help("Project Page")
                .accessibilityLabel("Project Page")
            } footer: {
                Text("CodeCaps reads quota from agent CLIs already signed in on this Mac." + sentenceGap
                     + "It never stores a provider API key.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Notifications & Alarms

struct SettingsNotificationsPage: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState

    var body: some View {
        SettingsPage {
            if let row = model.displaySections.first(where: {
                $0.providerKey == model.runawayAlertHistory.first?.providerKey
            }) ?? model.displaySections.first {
                Section {
                    UsageHistoryView(model: model, state: state, row: row)
                } header: {
                    Eyebrow("RECENT USAGE HISTORY")
                }
            }
            Section {
                Toggle("Reset Alarms For All Providers", isOn: $model.alarmsAll)
                    .help("The same switch as the All bell at the top of the Docked Bar.")
                    .accessibilityLabel("Reset Alarms For All Providers")
                Picker("Alert Sound", selection: $model.alarmSound) {
                    ForEach(ResetAlarmSound.defaultPickerOrder, id: \.self) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }
                .pickerStyle(.menu)
                .help("The sound played when a quota window resets." + sentenceGap
                      + "\"Silent\" mutes the alert sound entirely while keeping the notification banner.")
                .accessibilityLabel("Alert Sound")

                if model.alarmSound != .silent {
                    Label("\(model.alarmSound.pickerDetail)", systemImage: "speaker.wave.2")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Button("Preview Sound") {
                        model.previewResetSound()
                    }
                    .help("Preview the selected sound.")
                    .accessibilityLabel("Preview selected sound")
                }
            } header: {
                Eyebrow("RESET ALERTS")
            } footer: {
                Text("A provider's longest window, such as its weekly or monthly limit, alerts every time it resets, so you know a new week or month began." + sentenceGap
                     + "A shorter window, such as a 5-hour limit, alerts only if it reached its cap or came within 20% of it before resetting." + sentenceGap
                     + "Turn All off to choose providers one by one with the bell at the left of each row in the Docked Bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Alert on Runaway Usage", isOn: $model.burnRateAlertsEnabled)
                    .help("Alert when quota is being spent far faster than your own recent pattern.")
                    .accessibilityLabel("Alert on runaway usage")

                if model.burnRateAlertsEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Versus Your Recent Average")
                            Slider(value: $model.anomalyBaselineMultiplier,
                                   in: BurnRateMonitor.baselineRange,
                                   step: 0.5)
                            Text(String(format: "%.1f×", model.anomalyBaselineMultiplier))
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 38, alignment: .trailing)
                        }
                        .help("Alerts when the current hour is spending this many times faster than your measured average, using up to seven days of available readings. Recommended 5×.")
                        .accessibilityLabel("Alert threshold versus your recent average")

                        HStack {
                            Text("Versus Your Measured Peak")
                            Slider(value: $model.anomalyPeakMultiplier,
                                   in: BurnRateMonitor.peakRange,
                                   step: 0.1)
                            Text(String(format: "%.1f×", model.anomalyPeakMultiplier))
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 38, alignment: .trailing)
                        }
                        .help("Alerts when the current hour is spending this many times faster than your fastest measured interval. Recommended 2×.")
                        .accessibilityLabel("Alert threshold versus your measured peak")

                        let history = BurnRateMonitor.historySummary()
                        Text("\(history.sampleCount) saved local readings in the past 7 days." + sentenceGap
                             + "Each quota window needs at least one hour of valid measured intervals before its comparison can alert.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !model.runawayAlertHistory.isEmpty {
                            Divider().padding(.vertical, 4)
                            Text("Recent Runaway Alerts")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                            ForEach(model.runawayAlertHistory.prefix(5)) { alert in
                                Button {
                                    state.select(providerKey: alert.providerKey,
                                                 windowId: alert.windowId,
                                                 at: alert.timestamp,
                                                 in: model.displaySections,
                                                 readCompleted: model.lastChecked != nil)
                                } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("\(alert.providerLabel) · \(alert.windowLabel)")
                                                .font(.system(size: 11, weight: .medium))
                                            Text(alert.summary)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(alert.timestamp.formatted(date: .omitted, time: .shortened))
                                            .font(.system(size: 10).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Open \(alert.providerLabel) usage history")
                                .accessibilityLabel("Open \(alert.providerLabel), \(alert.windowLabel) usage history at \(alert.timestamp.formatted())")
                                .padding(.vertical, 1)
                            }
                            Button("View All in Runaway Alerts Console…") {
                                state.page = .runawayAlerts
                            }
                            .font(.system(size: 11))
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.top, 2)
                }
            } header: {
                Eyebrow("RUNAWAY USAGE")
            } footer: {
                Text("5× the measured average is the recommended starting point." + sentenceGap
                     + "The comparison uses only valid readings from the same quota period and account." + sentenceGap
                     + "The measured-peak check catches unusually fast depletion relative to your own past activity.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack(spacing: 8) {
                    Button("Send Test Notification") {
                        Task { await model.alarmManager.sendTestNotification() }
                    }
                    .help("Send Test Notification")
                    .accessibilityLabel("Send Test Notification")

                    if model.alarmManager.notificationsDenied {
                        Button("Open Notification Settings") {
                            NSWorkspace.shared.open(ResetAlarmManager.notificationSettingsURL)
                        }
                        .help("CodeCaps notifications are turned off." + sentenceGap
                              + "Opens the Notifications pane in System Settings.")
                        .accessibilityLabel("Open Notification Settings")
                    }
                }

                if let outcome = model.alarmManager.testNotificationOutcome {
                    Label {
                        Text(outcome.message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: outcome.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(outcome.isFailure ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .padding(.top, 2)
                }
            } footer: {
                Text("Triggers a test notification and alert sound to confirm macOS Notification permissions." + sentenceGap
                     + "The result is reported here, so a refused send tells you why instead of doing nothing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            // Learn the real authorization state on open, so the "Open
            // Notification Settings" affordance is there before the owner has
            // discovered the problem by pressing a button that does nothing.
            await model.alarmManager.refreshNotificationAuthorization()
        }
    }
}

/// A group's single commit-and-exercise button.  Prominent while the group is
/// dirty, plain when it is clean, so the instant-apply-versus-commit asymmetry
/// is visible rather than surprising.
struct CommitButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if prominent {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
            }
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Infisical Sync

/// The admin surface for Infisical as the source of truth (see INFISICAL.md).
///
/// CodeCaps is a single-user local app, so the owner IS the admin and the gate
/// is a no-op by design — this page is only reachable on his own Mac.  The
/// client identity is his own universal-auth machine identity, stored in his
/// Keychain like the read and ingest tokens already are; it is never embedded
/// in the app and never leaves the machine.  The iOS companion cannot hold a
/// client secret, so it stays out of Infisical entirely and keeps reading
/// through its existing quota API — the Mac app owns the Infisical read.
@MainActor
struct SettingsInfisicalPage: View {
    @ObservedObject var model: MonitorModel

    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var projectId = ""
    @State private var savedIdentity: InfisicalIdentityStore.Identity?
    @State private var operationId = UUID()
    @State private var hasIdentity = false
    @State private var pullEndpoint = ""
    @State private var pushEndpoint = ""
    @State private var refreshSeconds = ""
    @State private var working = false
    @State private var message: String?
    @State private var succeeded = false
    @State private var keyMessage: String?
    @State private var keySucceeded = false

    private var settings: InfisicalSettings { InfisicalSettings.shared }

    var body: some View {
        SettingsPage {
            Section {
                TextField("Client ID", text: $clientId,
                          prompt: Text("Client ID"))
                    .disabled(working)
                SecureField("Client Secret", text: $clientSecret,
                            prompt: Text(savedIdentity?.clientId == clientId && hasIdentity
                                         ? "Saved in Keychain (leave blank to keep)" : "Client Secret"))
                    .disabled(working)
                TextField("Project ID", text: $projectId)
                    .disabled(working)
                HStack {
                    if hasIdentity {
                        Button("Forget Setup", role: .destructive, action: forgetIdentity)
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    CommitButton(title: "Save Setup", prominent: !clientId.isEmpty, action: saveIdentity)
                        .disabled(working || candidateIdentity == nil)
                }
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(succeeded ? Theme.accent : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Eyebrow("CLIENT IDENTITY & PROJECT")
            } footer: {
                Text("Your own Infisical machine identity, kept in your Keychain." + sentenceGap
                     + "Nothing here is embedded in the app or sent anywhere but Infisical.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Status") { Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary) }
                LabeledContent("Environment") { Text(settingsEnvironment).font(.system(size: 11)) }
                if let savedIdentity {
                    LabeledContent("Saved Project ID") { Text(savedIdentity.projectId).font(.system(size: 11)) }
                }
                if let loaded = settings.lastLoadedAt {
                    LabeledContent("Last Synced") {
                        Text(loaded.formatted(date: .omitted, time: .shortened)).font(.system(size: 11))
                    }
                }
                if let error = settings.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Reload Now", action: reloadNow).disabled(working || !hasIdentity)
                }
            } header: {
                Eyebrow("SYNC STATUS")
            }

            Section {
                TextField("Pull Endpoint", text: $pullEndpoint)
                TextField("Push Endpoint", text: $pushEndpoint)
                TextField("Refresh Seconds", text: $refreshSeconds)
                HStack {
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    CommitButton(title: "Save Keys", prominent: keysDirty, action: saveKeys)
                        .disabled(working || !hasIdentity)
                }
                if let keyMessage = keyMessage {
                    Text(keyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(keySucceeded ? Theme.accent : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Eyebrow("MANAGED KEYS")
            } footer: {
                Text("Saving writes to Infisical first; a failed write fails the save." + sentenceGap
                     + "The pull and push pages write their endpoints through the same path.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { refreshFromStore(reloadSetup: true) }
    }

    private var statusLine: String {
        if hasIdentity {
            if let last = settings.lastLoadedAt {
                return "Active (Synced \(last.formatted(date: .omitted, time: .shortened)))"
            }
            return "Active"
        }
        return "Not configured"
    }

    private var settingsEnvironment: String {
        InfisicalSettings.defaultEnvironment()
    }

    private var keysDirty: Bool {
        pullEndpoint != (settings.value(for: InfisicalSettings.Keys.pullEndpoint) ?? "")
            || pushEndpoint != (settings.value(for: InfisicalSettings.Keys.pushEndpoint) ?? "")
            || refreshSeconds != (settings.value(for: InfisicalSettings.Keys.refreshSeconds) ?? "")
    }

    private var candidateIdentity: InfisicalIdentityStore.Identity? {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.isEmpty && savedIdentity?.clientId == id
            ? (savedIdentity?.clientSecret ?? "") : clientSecret
        guard !id.isEmpty, !secret.isEmpty, !project.isEmpty else { return nil }
        return InfisicalIdentityStore.Identity(clientId: id, clientSecret: secret, projectId: project)
    }

    private func refreshFromStore(reloadSetup: Bool = false) {
        savedIdentity = InfisicalIdentityStore.load()
        hasIdentity = savedIdentity != nil
        if reloadSetup {
            clientId = savedIdentity?.clientId ?? ""
            clientSecret = ""
            projectId = savedIdentity?.projectId ?? ""
        }
        pullEndpoint = settings.value(for: InfisicalSettings.Keys.pullEndpoint) ?? ""
        pushEndpoint = settings.value(for: InfisicalSettings.Keys.pushEndpoint) ?? ""
        refreshSeconds = settings.value(for: InfisicalSettings.Keys.refreshSeconds) ?? ""
    }

    private func beginOperation() -> UUID {
        let id = UUID()
        operationId = id
        working = true
        return id
    }

    private func saveIdentity() {
        guard let identity = candidateIdentity else { return }
        let operation = beginOperation()
        let revision = settings.beginSetupChange()
        message = nil
        keyMessage = nil
        Task {
            defer { if operationId == operation { working = false } }
            do {
                let committed = try await settings.validateAndConfigure(identity.configuration, revision: revision) {
                    try InfisicalIdentityStore.save(identity)
                }
                guard operationId == operation, settings.isCurrent(committed) else { return }
                model.adoptInfisicalEndpointsIfUnset()
                refreshFromStore(reloadSetup: true)
                succeeded = true
                message = "Setup saved and project verified against Infisical."
                NotificationCenter.default.post(name: .infisicalIdentityChanged, object: nil)
            } catch {
                guard operationId == operation, settings.isCurrent(revision) else { return }
                succeeded = false
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // Validation retires the old timer revision even on failure.
                // Resume refreshes for the still-persisted setup.
                NotificationCenter.default.post(name: .infisicalIdentityChanged, object: nil)
            }
        }
    }

    private func forgetIdentity() {
        // Clear can interrupt validation or a read/write. The core's revision
        // fence prevents their eventual completions from reinstalling old data.
        operationId = UUID()
        working = false
        do {
            try settings.clearConfiguration { try InfisicalIdentityStore.delete() }
            refreshFromStore(reloadSetup: true)
            succeeded = true
            message = "Setup removed." + sentenceGap + "Settings stay local until you add one again."
            keyMessage = nil
            NotificationCenter.default.post(name: .infisicalIdentityChanged, object: nil)
        } catch {
            succeeded = false
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NotificationCenter.default.post(name: .infisicalIdentityChanged, object: nil)
        }
    }

    private func reloadNow() {
        let operation = beginOperation()
        let revision = settings.revision
        Task {
            defer { if operationId == operation { working = false } }
            await settings.refresh()
            guard operationId == operation, settings.isCurrent(revision) else { return }
            model.adoptInfisicalEndpointsIfUnset()
            refreshFromStore()
        }
    }

    private func saveKeys() {
        let operation = beginOperation()
        let revision = settings.revision
        keyMessage = nil
        // Snapshot the form before any suspension; every key belongs to this
        // setup, even if a different settings window switches projects mid-save.
        let updates = [
            (InfisicalSettings.Keys.pullEndpoint, pullEndpoint),
            (InfisicalSettings.Keys.pushEndpoint, pushEndpoint),
            (InfisicalSettings.Keys.refreshSeconds, refreshSeconds),
        ]
        Task {
            defer { if operationId == operation { working = false } }
            do {
                var wroteAny = false
                for (key, field) in updates {
                    guard operationId == operation, settings.isCurrent(revision) else { return }
                    let value = field.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value != (settings.value(for: key) ?? "") else { continue }
                    try await settings.set(value, for: key, expectedRevision: revision)
                    wroteAny = true
                }
                guard operationId == operation, settings.isCurrent(revision) else { return }
                model.adoptInfisicalEndpointsIfUnset()
                refreshFromStore()
                keySucceeded = true
                keyMessage = wroteAny ? "Keys saved to Infisical." : "No changes to save."
            } catch {
                guard operationId == operation, settings.isCurrent(revision) else { return }
                refreshFromStore()
                keySucceeded = false
                keyMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
