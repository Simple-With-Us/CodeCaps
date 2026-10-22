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
                VStack(spacing: 16) {
                    if let error = model.lastError {
                        errorBanner(error)
                    }

                    if model.items.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.items) { item in
                            quotaCard(item)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
                Text("Fleet Status")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(model.items.count) Platforms Monitored")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 4)

            if let updated = model.lastUpdated {
                Text(updated.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fleet Status, \(model.items.count) platforms monitored")
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Quota Report Yet")
                .font(.headline)
            Text("Point this app at your Mac's sync endpoint, or open CodeCaps on the Mac so it can share readings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if model.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Refreshing Quotas...")
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
        // One canonical reading per allowance, the same resolution the Mac
        // app leads with.  Source detail lives in Settings, for debugging;
        // the main list just shows quotas.
        let scope: CompanionSourceScope = .allSources
        let isExpanded = expandedIds.contains(item.id) && item.isExpandable
        let short = item.cardShortWindow(scope: scope)
        let long = item.cardLongWindow(scope: scope)
        let cardWindows = item.cardWindows(scope: scope)
        let extraWindows = cardWindows.filter {
            $0.id != short?.window.id && $0.id != long?.window.id
        }

        return VStack(alignment: .leading, spacing: 12) {
            // Main clickable row
            HStack(alignment: .center, spacing: 12) {
                CompanionProviderLogo(item: item)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                    }

                    if let sub = item.subtitle {
                        companionSubtitleView(sub)
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    // The per-provider reset alarm, offered only while All is
                    // off: under All every provider alarms and there is
                    // nothing to choose.  Solid when on, faint when off.
                    if !model.alarmsAll {
                        Button {
                            model.toggleProviderAlarm(for: item.id)
                        } label: {
                            Image(systemName: item.isAlarmEnabled ? "bell.fill" : "bell")
                                .font(.system(size: 14))
                                .foregroundStyle(item.isAlarmEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reset alarm for \(item.title)")
                        .accessibilityValue(item.isAlarmEnabled ? "on" : "off")
                    }

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(item.cardDisplayPercent(scope: scope))
                            .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(item.cardStatusColor(scope: scope))
                    }

                    if item.isExpandable {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                }
            }

            // The cap line.  The Mac's menu-bar window and PiP say which
            // allowance ran out and when it lifts; the phone said nothing, so
            // a capped Codex or Antigravity plan looked like any other.
            if let atCapSummary = item.atCapSummary(scope: scope) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CompanionTheme.danger)
                    Text(atCapSummary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CompanionTheme.danger)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(CompanionTheme.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(CompanionTheme.danger.opacity(0.28), lineWidth: 0.5)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("At cap. \(atCapSummary)")
            }

            // Quota Bars side by side
            HStack(spacing: 12) {
                if let short {
                    CompanionMeterView(
                        caption: short.window.caption,
                        window: short.window
                    )
                }
                if let long, long.window.id != short?.window.id {
                    CompanionMeterView(
                        caption: long.window.caption,
                        window: long.window
                    )
                } else if short == nil {
                    if let first = cardWindows.first {
                        CompanionMeterView(caption: first.caption, window: first)
                    }
                }
            }

            // Multiple time periods / windows when expanded (only extra allowances not already displayed on the card)
            if isExpanded && !extraWindows.isEmpty {
                Divider()
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(extraWindows) { win in
                        windowRow(win)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isExpandable {
                toggleExpanded(item.id)
            }
        }
    }

    // MARK: - Individual Window Row

    private func windowRow(_ win: CompanionWindowItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(win.meterCaption)
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
        Section {
            ForEach(model.items) { item in
                HStack(spacing: 10) {
                    CompanionProviderLogo(item: item, size: 24)
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
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
        Section("Mac Sync Endpoint") {
            #if os(iOS)
            TextField("Endpoint URL (https://...)", text: $model.syncEndpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            #else
            TextField("Endpoint URL (https://...)", text: $model.syncEndpoint)
                .autocorrectionDisabled(true)
            #endif
            SecureField("Sync Bearer Token", text: $model.syncToken)
            Button("Remove Token", role: .destructive) {
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
                        Text("No secondary or mirror sources detected." + sentenceGap
                             + "All allowance windows are sourced directly from your primary sync feed.")
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
                                        Label("Sources differ ≥ 10 pts", systemImage: "exclamationmark.triangle.fill")
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
                    Text("Data Sources & Mirrors")
                } footer: {
                    Text("Per-feed detail for debugging." + sentenceGap
                         + "When two or more feeds reported within 20 minutes disagree by 10 points or more, the difference is listed here (hostnames are ignored). The main list always shows the newest canonical reading.")
                }
                .id("dataSourcesMirrorsSection")
                .accessibilityIdentifier("dataSourcesMirrorsSection")

        Section("Help") {
                    Link(
                        "Setup & Data Guide",
                        destination: URL(string: "https://codecaps.simplewithus.com/setup.html")!
                    )
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
                                Text("Refreshing Quotas...")
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
                            Text("Last updated \(updated.formatted(date: .omitted, time: .shortened))")
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

// MARK: - Companion Meter View

public struct CompanionMeterView: View {
    public let caption: String
    public let window: CompanionWindowItem

    public init(caption: String, window: CompanionWindowItem) {
        self.caption = caption
        self.window = window
    }

    public var body: some View {
        // Fixed columns so the percent sits in the same place on every card:
        // caption, bar, percent, countdown.  No per-window timestamps — the
        // header already carries the last-updated time.
        HStack(spacing: 4) {
            Text(caption)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.trailing)
                .frame(width: 32, alignment: .trailing)

            CompanionUsageBar(
                remainingPercent: window.isMasked ? nil : window.remainingPercent,
                elapsedFraction: window.isMasked ? nil : window.elapsedFraction(),
                height: 7
            )
            .frame(minWidth: 35, maxWidth: .infinity)

            Text(window.displayPercent)
                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(window.statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 40, alignment: .trailing)

            Text(window.meterCountdown())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 46, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
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
        return Color(uiColor: .tertiarySystemFill)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }

    private var pacingMarkerColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    private var pacingMarkerHaloColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.7) : Color.white.opacity(0.75)
    }

    public init(remainingPercent: Double?, elapsedFraction: Double? = nil, height: CGFloat = 7) {
        self.remainingPercent = remainingPercent
        self.elapsedFraction = elapsedFraction
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let safeRemaining = remainingPercent.map { min(100.0, max(0.0, $0)) }
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
                if let frac = elapsedFraction, frac >= 0, frac <= 1.0, totalWidth > 0 {
                    let markerX = CGFloat(frac) * totalWidth
                    let markerHeight: CGFloat = 18
                    let markerWidth: CGFloat = 3.0

                    // Halo
                    Capsule()
                        .fill(pacingMarkerHaloColor)
                        .frame(width: 5.5, height: markerHeight + 2)
                        .position(x: markerX, y: geo.size.height / 2)

                    // Line
                    Capsule()
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

    @Environment(\.colorScheme) private var colorScheme

    public init(item: CompanionQuotaItem, size: CGFloat = 36) {
        self.item = item
        self.size = size
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
            #if os(iOS)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            #else
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
            #endif

            if let customImage = loadCustomImage() {
                if customMarkMode == "template" {
                    customImage
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.primary)
                        .frame(width: size * 0.62, height: size * 0.62)
                } else {
                    customImage
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.62, height: size * 0.62)
                }
            } else if let logoName = resolvedLogoName {
                if isMonochrome {
                    Image(logoName)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.primary)
                        .frame(width: size * 0.62, height: size * 0.62)
                } else {
                    Image(logoName)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.62, height: size * 0.62)
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
