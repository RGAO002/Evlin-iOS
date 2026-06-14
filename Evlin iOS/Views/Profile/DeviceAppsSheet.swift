import SwiftUI

/// Per-app management for one device. Mirrors HTML 563-625.
/// Each row: app icon + name + toggle + tappable limit pill + progress bar.
/// Tap pill → expands inline 7-option limit picker (15/20/30/45/60/90/120 min).
///
/// HP-12: there is no backend for per-app usage/limits yet. At RUNTIME this
/// screen renders an honest "App limits coming soon" placeholder (the old
/// behavior keyed `DeviceAppsMockData` fixtures on literal "liam"/"maya", so
/// every real child saw emma's fake apps with invented usage). The fixture
/// rows are preview-only via `fixtureApps` (see #Preview below).
struct DeviceAppsSheet: View {
    let device: DeviceItem
    let childId: String
    var onClose: () -> Void = {}
    /// Preview-only seed. Runtime callers (ContentView's `.deviceDetail`
    /// route) leave this nil and trigger the real catalog fetch.
    var fixtureApps: [DeviceAppItem]? = nil

    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("evlin.childDeviceID") private var pairedChildID: String = ""

    @State private var apps: [DeviceAppItem] = []
    @State private var editingLimitFor: String? = nil
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if isLoading && apps.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if apps.isEmpty {
                emptyPlaceholder
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { idx, app in
                            appRow(app)
                            if idx < apps.count - 1 {
                                Rectangle()
                                    .fill(Color.evOutlineVariant.opacity(0.4))
                                    .frame(height: 1)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.evSurfaceContainerLowest)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 110)
                }
            }
        }
        .background(Color.evSurfaceContainerLow)
        // Pushed onto the parent NavigationStack — hide the system nav
        // bar and rely on this view's own header arrow / edge-swipe.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .onAppear {
            if let fixtureApps {
                apps = fixtureApps
                return
            }
            guard apps.isEmpty, let cid = UUID(uuidString: pairedChildID) else { return }
            isLoading = true
            Task {
                do {
                    let targets = try await apiClient.fetchLazyTagCatalogTargets(childDeviceID: cid)
                    let appTargets = targets.filter { $0.type == .app }
                    // 1) Render immediately: prettified names + any backend artwork.
                    apps = appTargets.map { t in
                        DeviceAppItem(
                            id: t.aliasKey.uuidString,
                            name: NameWithIcon.displayName(t.displayName),   // fixes casing (ig→Instagram, etc.)
                            iconSystemName: "app.fill",
                            brandColor: Color.evPrimary,
                            bgColor: Color.evPrimaryContainer,
                            enabled: true,
                            usedMin: 0,
                            limitMin: 60,
                            artworkURL: t.artworkURL
                        )
                    }
                    isLoading = false
                    // 2) Backfill real icons: when the backend gave no artwork URL,
                    //    resolve the App Store icon by name (cached) and patch it in.
                    for t in appTargets where t.artworkURL == nil {
                        let pretty = NameWithIcon.displayName(t.displayName)
                        if let url = await AppArtworkResolver.shared.artwork(forName: pretty),
                           let i = apps.firstIndex(where: { $0.id == t.aliasKey.uuidString }) {
                            apps[i].artworkURL = url
                        }
                    }
                } catch {
                    loadFailed = true
                    isLoading = false
                }
            }
        }
    }

    /// Empty state: honest message for "no apps yet" vs load failure.
    private var emptyPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: loadFailed ? "wifi.slash" : "app.dashed")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text(loadFailed ? "Couldn't load apps" : "No apps added yet")
                .font(.custom("Manrope", size: 16).weight(.heavy))
                .foregroundStyle(Color.evOnSurface)
            Text(loadFailed
                 ? "Check your connection and try again."
                 : "Apps captured on \(device.name) will show up here.")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("APP LIMITS")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text(device.name)
                    .font(.custom("Manrope", size: 19).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.evSurface
                .overlay(
                    Rectangle()
                        .fill(Color.evOutlineVariant)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    private func appRow(_ app: DeviceAppItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Group {
                    if let artworkURL = app.artworkURL {
                        AsyncImage(url: artworkURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            default:
                                // While loading or on failure, fall back to SF symbol
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(app.bgColor)
                                    Image(systemName: app.iconSystemName)
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(app.brandColor)
                                }
                            }
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(app.bgColor)
                            Image(systemName: app.iconSystemName)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(app.brandColor)
                        }
                        .frame(width: 40, height: 40)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(app.name)
                            .font(.custom("Manrope", size: 14).weight(.bold))
                            .foregroundStyle(Color.evOnSurface)

                        Spacer()

                        // Limit pill (tap to expand picker)
                        Button {
                            editingLimitFor = (editingLimitFor == app.id) ? nil : app.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                Text(DeviceAppsMockData.formatLimit(app.limitMin))
                                    .font(.custom("Manrope", size: 11).weight(.heavy))
                            }
                            .foregroundStyle(app.enabled ? Color.evPrimary : Color.evOutline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(app.enabled ? Color.evPrimaryContainer : Color.evSurfaceContainerHigh)
                            )
                        }
                        .buttonStyle(.plain)

                        Toggle("", isOn: Binding(
                            get: { app.enabled },
                            set: { newValue in
                                if let i = apps.firstIndex(where: { $0.id == app.id }) {
                                    apps[i].enabled = newValue
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(Color.evSecondary)
                    }

                    // Progress bar
                    progressBar(for: app)

                    // Status text
                    HStack {
                        Text(statusText(for: app))
                            .font(.custom("Inter", size: 10))
                            .foregroundStyle(app.enabled && app.usedMin >= app.limitMin
                                             ? Color.evError
                                             : Color.evOnSurfaceVariant)
                        Spacer()
                        if app.enabled && app.usedMin >= app.limitMin {
                            Text("LIMIT REACHED")
                                .font(.custom("Inter", size: 10).weight(.heavy))
                                .tracking(0.8)
                                .foregroundStyle(Color.evError)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if editingLimitFor == app.id {
                limitPicker(for: app)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
        }
    }

    private func progressBar(for app: DeviceAppItem) -> some View {
        let pct = min(1.0, Double(app.usedMin) / Double(max(app.limitMin, 1)))
        let color: Color = !app.enabled
            ? Color.evOutlineVariant
            : pct >= 1.0 ? Color.evError
            : pct > 0.75 ? Color(hex: 0xF97316)
            : Color.evSecondary
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.evSurfaceContainerHigh)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * (app.enabled ? pct : 0))
            }
        }
        .frame(height: 4)
    }

    private func statusText(for app: DeviceAppItem) -> String {
        guard app.enabled else { return "Limit off" }
        if app.usedMin == 0 { return "Not used today" }
        return "\(DeviceAppsMockData.formatUsed(app.usedMin)) used"
    }

    private func limitPicker(for app: DeviceAppItem) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(DeviceAppsMockData.limitOptions, id: \.self) { min in
                Button {
                    if let i = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[i].limitMin = min
                    }
                    editingLimitFor = nil
                } label: {
                    Text(DeviceAppsMockData.formatLimit(min))
                        .font(.custom("Manrope", size: 11).weight(.heavy))
                        .foregroundStyle(app.limitMin == min ? .white : Color.evOnSurface)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(app.limitMin == min ? Color.evPrimary : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(app.limitMin == min ? Color.evPrimary : Color.evOutlineVariant,
                                        lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview("Fixture apps (preview-only)") {
    NavigationStack {
        DeviceAppsSheet(
            device: DeviceItem(iconSystemName: "iphone", name: "iPhone 13",
                               detail: "Primary device", locked: false),
            childId: "liam",
            fixtureApps: DeviceAppsMockData.apps(for: "liam")
        )
    }
}

#Preview("Runtime (coming soon)") {
    NavigationStack {
        DeviceAppsSheet(
            device: DeviceItem(iconSystemName: "iphone", name: "iPhone 13",
                               detail: "Primary device", locked: false),
            childId: "liam"
        )
    }
}
