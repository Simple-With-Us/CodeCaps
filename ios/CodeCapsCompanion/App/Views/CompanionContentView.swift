import SwiftUI

/// The main content view of the CodeCaps iOS companion app.
public struct CompanionContentView: View {
    @ObservedObject public var model: CompanionQuotaModel
    @StateObject private var soundPlayer = AlarmSoundPlayer()
    @State private var showingSettings: Bool
    @State private var expandedIds: Set<String> = []
    @State private var platformOrderEditMode: EditMode = .inactive

    public init(model: CompanionQuotaModel, showingSettings: Bool = ProcessInfo.processInfo.arguments.contains("-openSettings")) {
        self.model = model
        self._showingSettings = State(initialValue: showingSettings)
        self._platformOrderEditMode = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("-reorderPlatforms") ? .active : .inactive
        )
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
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .scrollBounceBehavior(.always, axes: .vertical)
            #endif
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
            .task {
                if model.items.isEmpty || !model.syncEndpoint.isEmpty {
                    await model.refresh()
                }
            }
            .sheet(isPresented: $showingSettings) {
                #if os(iOS)
                companionSettingsView
                    .presentationDetents([.medium, .large])
                #else
                companionSettingsView
                #endif
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

                    Button("Companion Settings") {
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
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reset alarm for \(item.title)")
                        .accessibilityValue(item.isAlarmEnabled ? "on" : "off")
                    }

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
            CompanionUsageBar(
                remainingPercent: item.remainingPercent,
                elapsedFraction: item.elapsedFraction,
                height: 6
            )

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

            CompanionUsageBar(
                remainingPercent: win.remainingPercent,
                elapsedFraction: win.elapsedFraction(),
                height: 4
            )
            .frame(width: 52)

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
            ScrollViewReader { proxy in
                Form {
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
                    Toggle("Reset Alarms For All Providers", isOn: $model.alarmsAll)
                    Text("A provider's longest window alarms every time it resets." + sentenceGap
                         + "A shorter window alarms only if it came within 20% of its cap first."
                         + sentenceGap + "Turn this off to pick providers one by one with the bell on each card.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
            #if os(iOS)
            .environment(\.editMode, $platformOrderEditMode)
            #endif
            .navigationTitle("Companion Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .refreshable {
                await model.refresh()
            }
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-scrollToRefresh") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation {
                            proxy.scrollTo("refreshSection", anchor: .bottom)
                        }
                    }
                }
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

    public init(remainingPercent: Double?, elapsedFraction: Double? = nil, height: CGFloat = 6) {
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
                    let markerHeight = height + 4

                    // Halo
                    Rectangle()
                        .fill(pacingMarkerHaloColor)
                        .frame(width: 4, height: markerHeight + 2)
                        .position(x: markerX, y: geo.size.height / 2)

                    // Line
                    Rectangle()
                        .fill(pacingMarkerColor)
                        .frame(width: 2, height: markerHeight)
                        .position(x: markerX, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: height)
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
    /// `provider-antigravity` is the Antigravity Third-Party pool's solid star;
    /// the Gemini pool's `provider-gemini` keeps its colour gradient.
    private var isMonochrome: Bool {
        guard let name = item.providerLogoName else { return false }
        return ["provider-openai", "provider-cursor", "provider-grok", "provider-grok-bot", "provider-antigravity"]
            .contains(name)
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
            } else if let logoName = item.providerLogoName, logoExists(logoName) {
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
