import SwiftUI

/// The main content view of the CodeCaps iOS companion app.
public struct CompanionContentView: View {
    @ObservedObject public var model: CompanionQuotaModel
    @StateObject private var soundPlayer = AlarmSoundPlayer()
    @State private var showingSettings = false

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

                    // An honest empty state.  This used to render eight
                    // hardcoded quotas at 100% that were never measured, so a
                    // completely unconfigured app looked healthy.
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
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
                Text("\(model.items.count) Quotas Active")
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

    private func quotaCard(_ item: CompanionQuotaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                CompanionProviderLogo(item: item)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                    if let sub = item.subtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    }
                    .buttonStyle(.plain)

                    Text(item.displayPercent)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(item.statusColor)
                }
            }

            // Progress Bar
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
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Settings View

    private var companionSettingsView: some View {
        NavigationStack {
            Form {
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

                    // Parity with the macOS sheet, which had both of these all
                    // along.  The preview was simply missing here, and the
                    // picker it sat next to could not have worked regardless:
                    // the tone names it offered are macOS system sounds, which
                    // resolve to nothing on iOS.
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
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
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

