import SwiftUI

/// The main content view of the CodeCaps iOS companion app.
public struct CompanionContentView: View {
    @ObservedObject public var model: CompanionQuotaModel
    @StateObject private var soundPlayer = AlarmSoundPlayer()
    @State private var showingSettings = false
    @State private var expandedIds: Set<String> = []

    public init(model: CompanionQuotaModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard

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
            }
            .navigationTitle("CodeCaps")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Customize Platform Order")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                #endif
            }
            .refreshable {
                await model.refresh()
            }
            .sheet(isPresented: $showingSettings) {
                companionSettingsView
            }
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

    // MARK: - Header Card

    private var headerCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("FLEET STATUS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(model.items.count) Platforms Monitored")
                    .font(.headline)
            }
            Spacer()
            if let updated = model.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
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
            Button("Open Companion Settings") {
                showingSettings = true
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
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

    private func quotaCard(_ item: CompanionQuotaItem) -> some View {
        let isExpanded = expandedIds.contains(item.id)

        return VStack(alignment: .leading, spacing: 12) {
            // Main clickable row
            HStack(alignment: .center, spacing: 12) {
                CompanionProviderLogo(item: item)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                    if let sub = item.subtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        model.toggleAlarm(for: item.id)
                    } label: {
                        Image(systemName: item.isAlarmArmed ? "bell.fill" : "bell")
                            .font(.system(size: 14))
                            .foregroundStyle(item.isAlarmArmed ? Color.accentColor : .secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isAlarmArmed ? "Disarm reset alert" : "Arm reset alert")

                    Text(item.displayPercent)
                        .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(item.statusColor)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
            }

            // Overarching Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(trackColor)
                    if let pct = item.remainingPercent {
                        Capsule()
                            .fill(item.statusColor)
                            .frame(width: geo.size.width * CGFloat(min(max(pct, 0), 100)) / 100)
                    }
                }
            }
            .frame(height: 6)

            // Multiple time periods / windows when expanded
            if isExpanded {
                Divider()
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 10) {
                    Text("ALLOWANCE PERIODS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)

                    ForEach(item.windows) { win in
                        windowRow(win)
                    }

                    // Duplicate sources for the same data folded under the overarching section
                    if !item.duplicateWindows.isEmpty {
                        duplicateSourcesSection(item.duplicateWindows)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture {
            toggleExpanded(item.id)
        }
    }

    // MARK: - Individual Window Row

    private func windowRow(_ win: CompanionWindowItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(win.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                let cd = win.countdown()
                if !cd.isEmpty {
                    Text("Resets in \(cd)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(trackColor)
                    if let pct = win.remainingPercent {
                        Capsule().fill(win.statusColor)
                            .frame(width: geo.size.width * CGFloat(min(max(pct, 0), 100)) / 100)
                    }
                }
            }
            .frame(width: 48, height: 4)

            Text(win.displayPercent)
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(win.statusColor)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Duplicate Sources Folded Section

    private func duplicateSourcesSection(_ duplicates: [CompanionWindowItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .padding(.top, 4)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(duplicates) { dup in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(dup.label)
                                        .font(.system(size: 12, weight: .medium))
                                    if let src = dup.source ?? dup.via {
                                        Text("via \(src)")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                let cd = dup.countdown()
                                if !cd.isEmpty {
                                    Text("Resets in \(cd)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(dup.displayPercent)
                                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(dup.statusColor)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 4)
            } label: {
                Label("Additional Sources (\(duplicates.count))", systemImage: "arrow.triangle.merge")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Settings View

    private var companionSettingsView: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.items) { item in
                        HStack(spacing: 10) {
                            CompanionProviderLogo(item: item, size: 24)
                            Text(item.title)
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            Button {
                                model.movePlatformUp(id: item.id)
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.items.first?.id == item.id)

                            Button {
                                model.movePlatformDown(id: item.id)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.items.last?.id == item.id)
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
                    Text("Platform Order")
                } footer: {
                    Text("Customize the order of platforms shown on the main screen." + sentenceGap
                         + "Use the up/down arrows or drag to reorder.")
                }

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
                }

                Section("Alerts & Notifications") {
                    Toggle("Notify on Quota Reset", isOn: $model.notifyOnReset)
                    Picker("Reset Alert Sound", selection: $model.alarmSound) {
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

                Section {
                    Button("Refresh Quotas Now") {
                        Task { await model.refresh() }
                    }
                }
            }
            .navigationTitle("Companion Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
}

// MARK: - Provider Logo

public struct CompanionProviderLogo: View {
    public let item: CompanionQuotaItem
    public var size: CGFloat = 36

    public init(item: CompanionQuotaItem, size: CGFloat = 36) {
        self.item = item
        self.size = size
    }

    private var isMonochrome: Bool {
        guard let name = item.providerLogoName else { return false }
        return name == "provider-openai" || name == "provider-cursor" || name == "provider-grok" || name == "provider-grok-bot"
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

            if let logoName = item.providerLogoName, logoExists(logoName) {
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

    private func logoExists(_ name: String) -> Bool {
        #if os(iOS)
        return UIImage(named: name) != nil
        #else
        return NSImage(named: NSImage.Name(name)) != nil
        #endif
    }
}
