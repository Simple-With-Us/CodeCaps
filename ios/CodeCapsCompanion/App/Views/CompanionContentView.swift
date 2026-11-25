import SwiftUI

/// The main content view of the CodeCaps iOS companion app.
public struct CompanionContentView: View {
    @ObservedObject public var model: CompanionQuotaModel
    @StateObject private var soundPlayer = AlarmSoundPlayer()
    @State private var previewingKind: UsageAlertKind?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings: Bool
    @State private var expandedIds: Set<String> = []
    @State private var settingsTab: CompanionSettingsTab
    #if os(iOS)
    @State private var platformOrderEditMode: EditMode = .inactive
    #endif

    private enum CompanionSettingsTab: String, CaseIterable, Identifiable {
        case display = "Display"
        case sources = "Sources"
        case alarms = "Alarms"

        var id: String { rawValue }
    }

    public init(model: CompanionQuotaModel, showingSettings: Bool = ProcessInfo.processInfo.arguments.contains("-openSettings")) {
        self.model = model
        self._showingSettings = State(initialValue: showingSettings)
        // A launch argument picks the tab the settings sheet opens on, so the
        // screenshot capture can reach a tab without a tap.  Both spellings
        // are accepted:  -openAlarms is the capture's, and -openAlerts is
        // the one the alert work introduced for the same tab.
        let opensAlarms = ProcessInfo.processInfo.arguments.contains("-openAlarms")
            || ProcessInfo.processInfo.arguments.contains("-openAlerts")
        self._settingsTab = State(initialValue: opensAlarms ? .alarms : .display)
        #if os(iOS)
        self._platformOrderEditMode = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("-reorderPlatforms") ? .active : .inactive
        )
        #endif
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = model.lastError {
                        errorBanner(error)
                    }

                    if let stale = stalenessBannerMessage {
                        errorBanner(stale)
                    }

                    if model.items.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.items) { item in
                            quotaCard(item)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .scrollBounceBehavior(.always, axes: .vertical)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    fleetStatusToolbarContent
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    settingsToolbarButton
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    settingsToolbarButton
                }
                #endif
            }
            .refreshable {
                await model.refresh()
            }
            .task {
                if model.items.isEmpty || !model.syncEndpoint.isEmpty {
                    await model.refresh()
                }
            }
            .task(id: "\(scenePhase)-\(model.foregroundRefreshSeconds)") {
                guard scenePhase == .active, model.foregroundRefreshSeconds > 0 else { return }
                await model.refreshNotificationAuthorization()
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: UInt64(model.foregroundRefreshSeconds) * 1_000_000_000) }
                    catch { return }
                    guard !Task.isCancelled, scenePhase == .active else { return }
                    await model.refresh()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CodeCapsInAppAlert"))) { event in
                guard let values = event.userInfo, let id = values["id"] as? String,
                      let raw = values["kind"] as? String, let kind = UsageAlertKind(rawValue: raw),
                      let title = values["title"] as? String, let body = values["body"] as? String else { return }
                model.presentInAppAlert(id: id, kind: kind, title: title, body: body,
                                       sourceInstanceId: values["sourceInstanceId"] as? String)
            }
            .onChange(of: model.inAppAlert?.id) { _, _ in
                guard let alert = model.inAppAlert, !model.alertPreferences[alert.kind].notification else { return }
                let sound = model.alertPreferences[alert.kind].sound
                // In-app messages stay independent of system notification permission.
                soundPlayer.playInApp(sound)
            }
            .alert(item: Binding(get: { model.inAppAlert }, set: { if $0 == nil { model.dismissInAppAlert() } })) { alert in
                Alert(title: Text(alert.title), message: Text(alert.body), dismissButton: .default(Text("Done")))
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingSettings) {
                companionSettingsView
            }
            #else
            .sheet(isPresented: $showingSettings) {
                companionSettingsView
            }
            #endif
        }
    }

    // MARK: - Colors

    private var cardBackground: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private var trackColor: Color {
        #if os(iOS)
        return Color(uiColor: .tertiarySystemFill)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }

    private var settingsToolbarButton: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("CodeCaps Settings")
    }

    // MARK: - Fleet status (pinned navigation bar)

    private var fleetStatusToolbarContent: some View {
        HStack(spacing: 8) {
            Image("codecaps-mark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Your Plans")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CompanionTheme.supporting)
                    .lineLimit(1)
                Text("\(model.items.count) Platforms Monitored")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 4)

            if let updated = model.lastUpdated {
                Text(UpdatedStamp.label(updated))
                    .font(.caption)
                    .foregroundStyle(CompanionTheme.supporting)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your Plans, \(model.items.count) platforms monitored")
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.28), lineWidth: 0.5)
        )
    }

    /// The stale-feed banner, or nil when the readings are current.
    ///
    /// The header stamp already says the data's age (CC-214); what the page
    /// lacked was a cue you cannot scroll past.  The phone showed an
    /// eighteen-hour-old feed with every bar looking current (owner,
    /// Nov-15-2026): the pull kept serving old windows and nothing on the
    /// page said so.  Two honest states: the feed dated nothing (unverified),
    /// or the newest stamp passed the shared freshness threshold (stale,
    /// with the stamp).
    private var stalenessBannerMessage: String? {
        guard !model.items.isEmpty, model.hasDataSource else { return nil }
        guard let updated = model.lastUpdated else {
            return "These readings arrived without a timestamp." + sentenceGap
                + "Their age cannot be verified."
        }
        guard Date().timeIntervalSince(updated) >= QuotaFreshnessRule.staleAfter else { return nil }
        return "Readings are stale." + sentenceGap
            + "Last update \(UpdatedStamp.label(updated))." + sentenceGap
            + "Check that CodeCaps on the Mac is running and sharing."
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Quota Report Yet")
                .font(.headline)
            Text("Open CodeCaps on your Mac so it can share readings." + sentenceGap
                 + "Or add the share address in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if model.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Refreshing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 12) {
                    Button {
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("CodeCaps Settings") {
                        showingSettings = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Quota Card

    private func toggleExpanded(_ id: String) {
        withAnimation(.easeInOut(duration: 0.22)) {
            if expandedIds.contains(id) {
                expandedIds.remove(id)
            } else {
                expandedIds.insert(id)
            }
        }
    }

    @ViewBuilder
    private func companionSubtitleView(_ text: String) -> some View {
        if let range = text.range(of: "  (") {
            let prefix = String(text[..<range.lowerBound])
            let suffix = String(text[range.lowerBound...])
            (Text(prefix) + Text(suffix).italic())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func quotaCard(_ item: CompanionQuotaItem) -> some View {
        CompanionQuotaRow(
            item: item,
            isExpanded: expandedIds.contains(item.id),
            showSubtitle: model.items.contains { $0.id != item.id && $0.title == item.title },
            alarmsAll: model.alarmsAll,
            toggleExpanded: { toggleExpanded(item.id) },
            toggleAlarm: { model.toggleProviderAlarm(for: item.id) }
        )
    }

    // MARK: - Companion Provider Details View

    public struct CompanionProviderDetailsView: View {
        public let rows: [CompanionProviderDetailRow]

        public init(rows: [CompanionProviderDetailRow]) {
            self.rows = rows
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(row.value)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Individual Window Row

    private func windowRow(_ win: CompanionWindowItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(win.caption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                let cd = win.meterCountdown()
                if cd != "—" {
                    Text("Resets in \(cd)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)

            CompanionUsageBar(
                remainingPercent: win.isMasked ? nil : win.remainingPercent,
                elapsedFraction: win.isMasked ? nil : win.elapsedFraction(),
                height: 7
            )
            .frame(width: 52)

            Text(win.displayPercent)
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(win.statusColor)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Settings View

    private var itemsWithDuplicates: [CompanionQuotaItem] {
        model.items.filter { !$0.duplicateWindows.isEmpty }
    }

    private var companionSettingsView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Settings section", selection: $settingsTab) {
                    ForEach(CompanionSettingsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ScrollViewReader { proxy in
                    Form {
                        switch settingsTab {
                        case .display:
                            settingsDisplaySections
                        case .sources:
                            settingsSourcesSections
                        case .alarms:
                            settingsAlarmsSections
                        }
                    }
                    .onAppear {
                        if ProcessInfo.processInfo.arguments.contains("-showAlertCategories") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                proxy.scrollTo(UsageAlertKind.anomaly.rawValue, anchor: .top)
                            }
                        }
                        if ProcessInfo.processInfo.arguments.contains("-scrollToRefresh") {
                            settingsTab = .sources
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation {
                                    proxy.scrollTo("refreshSection", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, settingsTab == .display ? $platformOrderEditMode : Binding.constant(.inactive))
            #endif
            .navigationTitle("CodeCaps Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .refreshable {
                await model.refresh()
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSettings = false }
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingSettings = false }
                }
                #endif
            }
        }
    }

    @ViewBuilder
    private var settingsDisplaySections: some View {
        // Two pools of one provider share a title (Antigravity's Gemini and
        // Third-Party pools), so a row whose title is not unique also shows
        // the subtitle its home card carries (owner, 2026-11-06).
        let duplicatedTitles = Set(model.items.map(\.title).filter { title in
            model.items.count(where: { $0.title == title }) > 1
        })
        Section {
            ForEach(model.items) { item in
                HStack(spacing: 10) {
                    CompanionProviderLogo(item: item, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .medium))
                        if duplicatedTitles.contains(item.title),
                           let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
            .onMove(perform: model.movePlatform)

            if !model.platformOrder.isEmpty {
                Button("Reset Default Order") {
                    model.resetPlatformOrder()
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Platform Order")
                Spacer()
                #if os(iOS)
                Button(platformOrderEditMode == .active ? "Done" : "Edit") {
                    withAnimation {
                        platformOrderEditMode = platformOrderEditMode == .active ? .inactive : .active
                    }
                }
                .accessibilityLabel(platformOrderEditMode == .active
                                    ? "Done Reordering Platforms"
                                    : "Reorder Platforms")
                #endif
            }
        } footer: {
            Text("Customize the order of platforms shown on the main screen." + sentenceGap
                 + "Tap Edit, then drag to reorder.")
        }
    }

    @ViewBuilder
    private var settingsSourcesSections: some View {
        Section("Share Address") {
            #if os(iOS)
            TextField("Share Address (https://...)", text: $model.syncEndpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            #else
            TextField("Share Address (https://...)", text: $model.syncEndpoint)
                .autocorrectionDisabled(true)
            #endif
            SecureField("Access Code", text: $model.syncToken)
            Button("Remove Access Code", role: .destructive) {
                model.removeSyncToken()
            }
            .accessibilityIdentifier("removeSyncToken")
            .disabled(model.syncToken.isEmpty && model.tokenStorageError == nil)
            if let tokenStorageError = model.tokenStorageError {
                Text(tokenStorageError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .id("syncTokenSection")

        Section {
                    if itemsWithDuplicates.isEmpty {
                        Text("No extra readings yet." + sentenceGap
                             + "Each plan shows the newest reading.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(itemsWithDuplicates) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    CompanionProviderLogo(item: item, size: 20)
                                    Text(item.title)
                                        .font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    if item.sourceCount > 1,
                                       item.hasSourceDiscrepancy(scope: .allSources) {
                                        Label("Readings Differ", systemImage: "exclamationmark.triangle.fill")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.orange)
                                    }
                                }

                                ForEach(item.sourceDetailWindows) { reading in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(reading.meterCaption)
                                                    .font(.system(size: 12, weight: .medium))
                                                if let src = reading.source ?? reading.via {
                                                    Text("via \(src)")
                                                        .font(.system(size: 10, weight: .medium))
                                                        .foregroundStyle(.secondary)
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 1.5)
                                                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                                }
                                                if item.isStaleInSourceDetail(reading, scope: .allSources) {
                                                    Text("Stale")
                                                        .font(.system(size: 10, weight: .semibold))
                                                        .foregroundStyle(.secondary)
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 1.5)
                                                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                                                }
                                            }
                                            if !reading.countdown().isEmpty {
                                                Text("Resets in \(reading.countdown())")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text(reading.displayPercent)
                                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                                            .foregroundStyle(reading.statusColor)
                                    }
                                    .padding(.vertical, 2)
                                    .opacity(item.isStaleInSourceDetail(reading, scope: .allSources) ? 0.72 : 1)
                                }

                                if item.sourceCount > 1,
                                   item.hasSourceDiscrepancy(scope: .allSources) {
                                    ForEach(item.sourceDiscrepancies(scope: .allSources)) { disc in
                                        HStack(spacing: 5) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.orange)
                                            Text(disc.description)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Other Readings")
                } footer: {
                    Text("Readings from each source." + sentenceGap
                         + "When two sources that reported within 20 minutes differ by 10 points or more, the difference shows here." + sentenceGap
                         + "The main list always shows the newest reading.")
                }
                .id("dataSourcesMirrorsSection")
                .accessibilityIdentifier("dataSourcesMirrorsSection")

        Section("Help") {
            Link(
                "Setup & Data Guide",
                destination: URL(string: "https://codecaps.simplewithus.com/setup.html")!
            )
        }

        Section("About") {
            LabeledContent("Version") {
                let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
                Text("\(short) (\(build))")
                    .foregroundStyle(.secondary)
            }
        }

                Section {
                    Button {
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        Task { await model.refresh() }
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            if model.isRefreshing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text("Refreshing…")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                Text("Refresh Quotas Now")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsRefreshButtonStyle())
                    .disabled(model.isRefreshing)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let updated = model.lastUpdated {
                            Text("Last updated \(UpdatedStamp.label(updated))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let error = model.lastError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .id("refreshSection")
    }

    @ViewBuilder
    private var settingsAlarmsSections: some View {
        Section("Alert Delivery") {
            Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
            Button("Allow System Notifications") { Task { await model.requestNotificationPermission() } }
            #if os(iOS)
            Button("Open Notification Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            #endif
            Picker("Refresh While Open", selection: $model.foregroundRefreshSeconds) {
                Text("Manual").tag(0)
                Text("Every 30 seconds").tag(30)
                Text("Every minute").tag(60)
                Text("Every 5 minutes").tag(300)
            }
            Text("In-app messages and foreground refresh stop when CodeCaps closes." + sentenceGap
                 + "Remote push is optional and is required for system notifications while the app is closed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Alert Devices") {
            Picker("Receive Alerts From", selection: Binding(
                get: { model.alertPreferences.sourceInstanceId ?? "" },
                set: { model.alertPreferences.sourceInstanceId = $0.isEmpty ? nil : $0 })) {
                Text("All reporting devices").tag("")
                ForEach(model.alertSourceDevices.keys.sorted(), id: \.self) { id in
                    Text(model.alertSourceDevices[id] ?? "Mac").tag(id)
                }
                if let selected = model.alertPreferences.sourceInstanceId, model.alertSourceDevices[selected] == nil {
                    Text("Selected device unavailable").tag(selected)
                }
            }
            Text("Device choices use the identity reported by the collector." + sentenceGap
                 + "A selected device excludes reports with no matching device identity; display source choices remain separate.")
                .font(.caption).foregroundStyle(.secondary)
        }
        #if os(iOS)
        RemotePushSettingsView()
        #endif
        ForEach(UsageAlertKind.allCases) { kind in
            Section(kind.title) {
                Toggle("Enable Alerts", isOn: Binding(
                    get: { model.alertPreferences[kind].enabled },
                    set: { model.alertPreferences[kind].enabled = $0 }))
                Text(kind.detail).font(.caption2).foregroundStyle(.secondary)
                if model.alertPreferences[kind].enabled {
                    Toggle("System Notifications", isOn: Binding(
                        get: { model.alertPreferences[kind].notification },
                        set: { model.alertPreferences[kind].notification = $0 }))
                    Toggle("In-App Messages", isOn: Binding(
                        get: { model.alertPreferences[kind].popup },
                        set: { model.alertPreferences[kind].popup = $0 }))
                    Picker("Sound", selection: Binding(
                        get: { model.alertPreferences[kind].sound },
                        set: { model.alertPreferences[kind].sound = $0 })) {
                        ForEach(ResetAlarmSound.defaultPickerOrder, id: \.self) { sound in
                            Text(sound.displayName).tag(sound)
                        }
                    }
                    Text(model.alertPreferences[kind].sound.pickerDetail)
                        .font(.caption2).foregroundStyle(.secondary)
                    if model.alertPreferences[kind].sound == .systemDefault {
                        Text("The default chime plays only through system notifications; in-app messages stay silent.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button(model.alertPreferences[kind].sound == .systemDefault ? "Preview System Chime" : "Preview Sound") {
                        previewingKind = kind
                        soundPlayer.preview(model.alertPreferences[kind].sound)
                    }
                        .disabled(model.alertPreferences[kind].sound == .silent)
                    if previewingKind == kind, let result = soundPlayer.lastPreview {
                        Text(result.message).font(.caption2)
                            .foregroundStyle(result.isFailure ? Color.orange : Color.secondary)
                    }
                }
            }
            .id(kind.rawValue)
        }
        Section("Reset Alarms") {
            Toggle("Reset Alarms For All Providers", isOn: $model.alarmsAll)
            if !model.alarmsAll {
                ForEach(Array(Set(model.items.map(\.providerKey))).sorted(), id: \.self) { provider in
                    Toggle((model.items.first(where: { $0.providerKey == provider })?.title ?? provider)
                            .components(separatedBy: " · ").first ?? provider,
                           isOn: Binding(get: { model.remoteResetProviderIsSelected(provider) },
                                         set: { model.setRemoteResetProvider(provider, enabled: $0) }))
                }
            }
            Text("These provider choices apply to remote resets too." + sentenceGap
                 + "Remote resets cover whole providers; a partial model-pool selection on cards stays local and excludes that provider from remote resets.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Anomalies and runaway usage use measurements from the Mac collector." + sentenceGap
                 + "Quota Exhaustion means zero quota remaining; the Mac's forecast Running Out warning is not supplied by this feed.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("A provider's longest window alarms every time it resets." + sentenceGap
                 + "A shorter window alarms only if it came within 20% of its cap first."
                 + sentenceGap + "Turn this off to pick providers one by one with the bell on each card.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Test Notification Sound", selection: $model.alarmSound) {
                ForEach(ResetAlarmSound.defaultPickerOrder, id: \.self) { sound in
                    Text(sound.displayName).tag(sound)
                }
            }
            Text(model.alarmSound.pickerDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                soundPlayer.preview(model.alarmSound)
            } label: {
                Label("Preview Sound", systemImage: "speaker.wave.2")
            }
            .disabled(model.alarmSound == .silent)

            if let preview = soundPlayer.lastPreview {
                Label {
                    Text(preview.message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: preview.isFailure
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                }
                .font(.caption2)
                .foregroundStyle(preview.isFailure ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }

            Button {
                Task { await model.sendTestNotification() }
            } label: {
                Label("Send Test Notification", systemImage: "bell.badge")
            }

            if model.notificationsDenied {
                Button {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #endif
                } label: {
                    Label("Open Notification Settings", systemImage: "gearshape")
                }
            }

            if let outcome = model.testNotificationOutcome {
                Label {
                    Text(outcome.message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: outcome.isFailure
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                }
                .font(.caption2)
                .foregroundStyle(outcome.isFailure ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
        }
    }
}

/// A compact quota row shared by the phone list and native layout probes.
/// Selection, caps and detail windows still come from the companion model.
public struct CompanionQuotaRow: View {
    public let item: CompanionQuotaItem
    public var isExpanded: Bool
    public var showSubtitle: Bool
    public var alarmsAll: Bool
    private let toggleExpanded: () -> Void
    private let toggleAlarm: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var identityWidth: CGFloat = 112

    public init(item: CompanionQuotaItem, isExpanded: Bool = false,
                showSubtitle: Bool = false, alarmsAll: Bool = true,
                toggleExpanded: @escaping () -> Void = {}, toggleAlarm: @escaping () -> Void = {}) {
        self.item = item
        self.isExpanded = isExpanded
        self.showSubtitle = showSubtitle
        self.alarmsAll = alarmsAll
        self.toggleExpanded = toggleExpanded
        self.toggleAlarm = toggleAlarm
    }

    private var windows: [CompanionWindowItem] { item.cardWindows(scope: .allSources) }
    private var usableExtra: CompanionWindowItem? {
        guard item.providerKey == "muse-assist" else { return nil }
        return windows.first {
            QuotaWindowVocabulary.isMuseAssistExtra(providerKey: item.providerKey,
                windowToken: $0.rawWindowToken, label: $0.label, resetAt: $0.resetAt)
                && (($0.remainingPercent ?? 0) > 0 || ($0.absoluteRemaining ?? 0) > 0)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { identity; Spacer(minLength: 0); alarmButton }
                    summary
                }
                .padding(.vertical, 10)
            } else {
                HStack(spacing: 8) {
                    identity.frame(width: identityWidth, alignment: .leading)
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    alarmButton
                    if item.isExpandable {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
                .padding(.vertical, 2)
            }
            if isExpanded && item.isExpandable {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.cardDetailWindows(scope: .allSources)) { window in
                        CompanionMeterView(caption: window.caption, window: window)
                    }
                }
                .padding(.leading, 28)
                .padding(.bottom, 10)
            }
            Divider()
        }
        .contentShape(Rectangle())
        .onTapGesture { if item.isExpandable { toggleExpanded() } }
        .accessibilityIdentifier("quota-row-\(item.id)")
        .accessibilityActions {
            if item.isExpandable {
                Button(isExpanded ? "Collapse Details" : "Show Details", action: toggleExpanded)
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 6) {
            CompanionProviderLogo(item: item, size: 22, showsBackground: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .italic(item.atCapWindow(scope: .allSources) != nil && usableExtra == nil)
                    .foregroundStyle(item.atCapWindow(scope: .allSources) != nil && usableExtra == nil
                        ? CompanionTheme.supporting : .primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(0.85)
                if showSubtitle, let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }

        }
    }

    @ViewBuilder private var alarmButton: some View {
            if !alarmsAll {
                Button(action: toggleAlarm) {
                    Image(systemName: item.isAlarmEnabled ? "bell.fill" : "bell")
                        .font(.caption)
                        .foregroundStyle(item.isAlarmEnabled ? CompanionTheme.accent : .secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset alarm for \(item.title)")
                .accessibilityValue(item.isAlarmEnabled ? "On" : "Off")
            }
    }

    @ViewBuilder private var summary: some View {
        if let cap = item.atCapSummary(scope: .allSources) {
            if let extra = usableExtra {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cap).font(.caption2).foregroundStyle(CompanionTheme.supporting)
                    CompanionMeterView(caption: extra.caption, window: extra)
                }
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cap)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let exact = item.atCapResetExactTime(scope: .allSources), !exact.isEmpty {
                        Text(exact).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let cue = item.atCapReadingAgeCue(scope: .allSources) {
                        Text(cue).font(.caption2).foregroundStyle(CompanionTheme.supporting)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } else if windows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let lastReading = item.deadCopyObservedAt {
                    Text("Waiting for a fresh reading")
                        .font(.caption).foregroundStyle(CompanionTheme.supporting)
                    Text("Last reading \(UpdatedStamp.label(lastReading))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Unavailable").font(.caption).foregroundStyle(CompanionTheme.supporting)
                }
            }
        } else {
            let first = item.cardShortWindow(scope: .allSources)?.window ?? windows.first
            let second = item.cardLongWindow(scope: .allSources)?.window
            HStack(spacing: 8) {
                if let first {
                    CompanionMeterView(caption: first.caption, window: first)
                }
                if let second, second.id != first?.id {
                    CompanionMeterView(caption: second.caption, window: second)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1).accessibilityHidden(true)
                }
            }
        }
    }
}

// MARK: - Companion Meter View

public struct CompanionMeterView: View {
    public let caption: String
    public let window: CompanionWindowItem

    public init(caption: String, window: CompanionWindowItem) {
        self.caption = caption
        self.window = window
    }

    private var pacingBackground: Color {
        guard !window.isMasked, let remaining = window.remainingPercent, remaining.isFinite else { return .clear }
        if let elapsed = window.elapsedFraction(), elapsed.isFinite, elapsed > 0, elapsed < 1 {
            let delta = remaining - (1 - elapsed) * 100
            if delta >= 15 { return .green.opacity(0.18 + 0.12 * min(1, (delta - 15) / 40)) }
            if delta >= 0 { return .green.opacity(0.12) }
            if delta <= -20 { return .red.opacity(0.20 + 0.15 * min(1, (-delta - 20) / 40)) }
            return .orange.opacity(0.18)
        }
        if remaining >= 50 { return .green.opacity(0.12) }
        return remaining >= 20 ? .orange.opacity(0.16) : .red.opacity(0.22)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                CompanionUsageBar(
                    remainingPercent: window.isMasked ? nil : window.remainingPercent.flatMap { $0.isFinite ? $0 : nil },
                    elapsedFraction: window.isMasked ? nil : window.elapsedFraction().flatMap { $0.isFinite ? $0 : nil }, height: 6
                )
                .frame(minWidth: 24)
                Text(window.displayPercent)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(pacingBackground, in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()
            }
            Text(window.meterCountdown())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if let cue = window.staleReadingCue() {
                Text(cue)
                    .font(.caption2)
                    .foregroundStyle(CompanionTheme.warning)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption), \(window.displayPercent) remaining, resets in \(window.meterCountdown())\(window.staleReadingCue().map { ", \($0)" } ?? "")")
    }
}

// MARK: - Companion Usage Bar

public struct CompanionUsageBar: View {
    public let remainingPercent: Double?
    public let elapsedFraction: Double?
    public var height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private var barUsedColor: Color {
        CompanionTheme.barUsed
    }

    private var barRemainingColor: Color {
        CompanionTheme.barRemaining
    }

    private var trackColor: Color {
        #if os(iOS)
        // The Mac's track token: a faint black on light, a faint white on dark.
        return colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }

    private var pacingMarkerColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    private var pacingMarkerHaloColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.7) : Color.white.opacity(0.7)
    }

    public init(remainingPercent: Double?, elapsedFraction: Double? = nil, height: CGFloat = 7) {
        self.remainingPercent = remainingPercent
        self.elapsedFraction = elapsedFraction
        self.height = height
    }

    /// Where the marker and its halo sit, as the Mac bar lays them out: the
    /// marker at the elapsed fraction, kept clear of the rounded ends, and the
    /// halo trimmed to the bar.  Narrower than the marker, it sits in the middle.
    private func markerLayout(fraction: CGFloat, totalWidth: CGFloat, markerWidth: CGFloat, haloPadding: CGFloat)
        -> (center: CGFloat, haloStart: CGFloat, haloEnd: CGFloat) {
        guard totalWidth > markerWidth else { return (totalWidth / 2, 0, totalWidth) }
        let half = markerWidth / 2
        let cap = height / 2
        var center = min(max(fraction * totalWidth, half), totalWidth - half)
        if totalWidth >= (half + cap) * 2 {
            if center - half < cap { center = half }
            else if totalWidth - (center + half) < cap { center = totalWidth - half }
        }
        let reach = half + haloPadding
        return (center, max(0, center - reach), min(totalWidth, center + reach))
    }

    public var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let safeRemaining = remainingPercent.flatMap { $0.isFinite ? min(100.0, max(0.0, $0)) : nil }
            let remainingWidth = safeRemaining.map { CGFloat($0 / 100.0) * totalWidth }
            let usedWidth = remainingWidth.map { totalWidth - $0 }

            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(trackColor)
                    .frame(height: height)

                // Two-tone segments: Used (Red) on left, Remaining (Green/Teal) on right
                if let usedW = usedWidth, let remW = remainingWidth, totalWidth > 0 {
                    HStack(spacing: 0) {
                        if usedW > 0 {
                            Rectangle()
                                .fill(barUsedColor)
                                .frame(width: usedW)
                        }
                        if remW > 0 {
                            Rectangle()
                                .fill(barRemainingColor)
                                .frame(width: remW)
                        }
                    }
                    .clipShape(Capsule())
                    .frame(height: height)
                }

                // Pacing marker line (elapsed time fraction)
                if safeRemaining != nil, let frac = elapsedFraction, frac.isFinite, frac >= 0, frac <= 1.0, totalWidth > 0 {
                    // Same placement as the Mac bar: a 1 pt halo, a position that
                    // stays off the rounded ends, and a halo trimmed to the bar.
                    let markerWidth: CGFloat = 3.0
                    let haloPadding: CGFloat = 1.0
                    let markerHeight: CGFloat = 18
                    let layout = markerLayout(fraction: CGFloat(frac), totalWidth: totalWidth, markerWidth: markerWidth, haloPadding: haloPadding)
                    let markerX = layout.center

                    // Halo
                    Rectangle()
                        .fill(pacingMarkerHaloColor)
                        .frame(width: layout.haloEnd - layout.haloStart, height: markerHeight + haloPadding * 2)
                        .position(x: (layout.haloStart + layout.haloEnd) / 2, y: geo.size.height / 2)

                    // Line
                    Rectangle()
                        .fill(pacingMarkerColor)
                        .frame(width: markerWidth, height: markerHeight)
                        .position(x: markerX, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: max(height, 20))
    }
}

// MARK: - Provider Logo

public struct CompanionProviderLogo: View {
    public let item: CompanionQuotaItem
    public var size: CGFloat = 36
    public var showsBackground: Bool = true
    private var markSize: CGFloat { showsBackground ? size * 0.62 : size }

    @Environment(\.colorScheme) private var colorScheme

    public init(item: CompanionQuotaItem, size: CGFloat = 36, showsBackground: Bool = true) {
        self.item = item
        self.size = size
        self.showsBackground = showsBackground
    }

    private var customMarkURL: URL? {
        CompanionQuotaModel.customMarkURL(for: item.providerKey, isDarkMode: colorScheme == .dark)
    }

    private var customMarkMode: String {
        CompanionQuotaModel.customMarkMode(for: item.providerKey)
    }

    /// One-colour marks render as templates so they follow Light and Dark.
    /// Antigravity's supplied arch and Gemini's star keep their color here.
    private var isMonochrome: Bool {
        guard let name = resolvedLogoName else { return false }
        return ["provider-openai", "provider-cursor", "provider-grok", "provider-grok-bot", "provider-copilot"]
            .contains(name)
    }

    /// Server-first logo resolution, mirroring the Mac app's
    /// `PlatformLogoImage.bundledImage`: the manifest's `iconHint` wins when
    /// it resolves to a bundled asset, otherwise the hardcoded map runs, so
    /// a bad hint can never blank a mark the map would have found.
    private var resolvedLogoName: String? {
        if let hint = item.iconHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            let hinted = hint.hasPrefix("provider-") ? hint : "provider-\(hint)"
            if logoExists(hinted) { return hinted }
        }
        guard let name = item.providerLogoName, logoExists(name) else { return nil }
        return name
    }

    public var body: some View {
        ZStack {
            if showsBackground {
            #if os(iOS)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            #else
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
            #endif

            }

            if let customImage = loadCustomImage() {
                if customMarkMode == "template" {
                    customImage
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.primary)
                        .frame(width: markSize, height: markSize)
                } else {
                    customImage
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: markSize, height: markSize)
                }
            } else if let logoName = resolvedLogoName {
                if isMonochrome {
                    Image(logoName)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.primary)
                        .frame(width: markSize, height: markSize)
                } else {
                    Image(logoName)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: markSize, height: markSize)
                }
            } else {
                Image(systemName: item.fallbackSymbolName)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private func loadCustomImage() -> Image? {
        guard let url = customMarkURL else { return nil }
        #if canImport(UIKit)
        if let uiImg = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: uiImg)
        }
        #elseif canImport(AppKit)
        if let nsImg = NSImage(contentsOf: url) {
            return Image(nsImage: nsImg)
        }
        #endif
        return nil
    }

    private func logoExists(_ name: String) -> Bool {
        #if os(iOS)
        return UIImage(named: name) != nil
        #else
        return NSImage(named: NSImage.Name(name)) != nil
        #endif
    }
}

// MARK: - Settings Refresh Button Style

/// Dedicated button style providing instant visual feedback on touch down
/// across the entire row, avoiding UIKit delay/suppression in Form lists.
public struct SettingsRefreshButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.15) : Color.clear)
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
