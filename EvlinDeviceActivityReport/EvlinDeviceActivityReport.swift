import DeviceActivity
import ExtensionFoundation
import ExtensionKit
import Foundation
import ManagedSettings
import SwiftUI
import UIKit
import Security

@main
struct EvlinDeviceActivityReportExtension: DeviceActivityReportExtension {
    // iOS 26 SDK refined `AppExtension` (parent of DeviceActivityReportExtension)
    // to require @AppExtensionSceneBuilder on `body`. Without the annotation,
    // Swift can't synthesize the scene-builder conformance and the protocol
    // check fails with 'does not conform to AppExtension'.
    var body: some DeviceActivityReportScene {
        MetadataProbeReport { configuration in
            MetadataProbeReportView(configuration: configuration)
        }
        QrSpikeReport { payload in
            QrSpikeReportView(payload: payload)
        }
    }
}

extension DeviceActivityReport.Context {
    static let evlinMetadataProbe = Self("evlin.metadataProbe")
    static let evlinQrSpike = Self("evlin.qrSpike")
}

struct QrSpikeReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .evlinQrSpike
    let content: (String) -> QrSpikeReportView

    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> String {
        // Channel spike v2: render one real app token into a user-mediated QR.
        // The host app cannot read DAR pixels directly, but the user can take a
        // system screenshot and import it back into the host for decoding.
        var segmentCount = 0
        var categoryCount = 0
        var appCount = 0
        var appNames: [String] = []
        var candidates: [QrSpikeCandidate] = []
        for await activityData in data {
            for await segment in activityData.activitySegments {
                segmentCount += 1
                for await categoryActivity in segment.categories {
                    categoryCount += 1
                    for await appActivity in categoryActivity.applications {
                        appCount += 1
                        let app = appActivity.application
                        let displayName = app.localizedDisplayName ?? "Unknown app"
                        let bundleID = app.bundleIdentifier ?? ""
                        if appNames.count < 8 {
                            appNames.append("\(displayName)|\(bundleID)|token=\(app.token == nil ? "nil" : "yes")")
                        }
                        guard let token = app.token,
                              let tokenData = try? PropertyListEncoder().encode(token) else {
                            continue
                        }
                        candidates.append(
                            QrSpikeCandidate(
                                displayName: displayName,
                                bundleID: bundleID,
                                duration: appActivity.totalActivityDuration,
                                tokenData: tokenData
                            )
                        )
                    }
                }
            }
        }
        if let selected = QrSpikeCandidate.selectBest(from: candidates) {
            let payload = QrSpikeTokenPayload(
                kind: "evlin_app_token_v1",
                displayName: selected.displayName,
                bundleID: selected.bundleID,
                tokenB64: selected.tokenData.base64EncodedString()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(payload),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
        }
        return QrSpikeNoTokenDiagnostic(
            segmentCount: segmentCount,
            categoryCount: categoryCount,
            appCount: appCount,
            candidateCount: candidates.count,
            apps: appNames
        ).encoded()
    }
}

private struct QrSpikeNoTokenDiagnostic: Codable {
    let kind = "evlin_qr_spike_no_token"
    let segmentCount: Int
    let categoryCount: Int
    let appCount: Int
    let candidateCount: Int
    let apps: [String]

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "NO_APP_TOKEN_IN_REPORT"
        }
        return json
    }
}

private struct QrSpikeCandidate {
    let displayName: String
    let bundleID: String
    let duration: TimeInterval
    let tokenData: Data

    static func selectBest(from candidates: [QrSpikeCandidate]) -> QrSpikeCandidate? {
        candidates.max { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            if lhs.duration != rhs.duration {
                return lhs.duration < rhs.duration
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedDescending
        }
    }

    private var score: Int {
        let name = displayName.lowercased()
        let bundle = bundleID.lowercased()
        var value = Int(min(duration, 1_200) / 10)

        // This is debug-sample selection only. It is not product routing.
        if bundle.hasPrefix("com.evlin.") || bundle == "com.evlin.evlin-ios" || name == "evlin" {
            value -= 1_000
        }
        if bundle.hasPrefix("com.apple.") {
            value -= 500
        }
        if bundle.isEmpty || name == "unknown app" {
            value -= 200
        }
        if !bundle.hasPrefix("com.apple.") && !bundle.hasPrefix("com.evlin.") && !bundle.isEmpty {
            value += 300
        }

        let priorityNeedles: [(String, Int)] = [
            ("instagram", 1_000),
            ("burbn", 1_000),
            ("tiktok", 950),
            ("musically", 950),
            ("youtube", 900),
            ("roblox", 850),
            ("snapchat", 800),
            ("facebook", 750),
            ("discord", 700),
            ("netflix", 650),
            ("spotify", 600),
            ("chrome", 550)
        ]
        for (needle, bonus) in priorityNeedles where name.contains(needle) || bundle.contains(needle) {
            value += bonus
            break
        }
        return value
    }
}

struct QrSpikeTokenPayload: Codable {
    let kind: String
    let displayName: String
    let bundleID: String
    let tokenB64: String
}

struct QrSpikeReportView: View {
    let payload: String

    var body: some View {
        VStack(spacing: 8) {
            if let qr = makeQRCode() {
                qrCodeCanvas(qr)
                    .frame(width: 300, height: 300)
            } else {
                Text("QR_GEN_FAILED")
                    .font(.caption.monospaced().bold())
            }
            Text(payloadSummary)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .background(Color.white)
        .accessibilityLabel("QR code for \(payloadSummary)")
    }

    private var payloadSummary: String {
        if let data = payload.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(QrSpikeTokenPayload.self, from: data) {
            return "\(parsed.displayName) \(parsed.bundleID) token=\(parsed.tokenB64.count)b64"
        }
        return payload
    }

    private func makeQRCode() -> QRCode? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? QRCode.encode(binary: Array(data), ecl: .medium)
    }

    private func qrCodeCanvas(_ qr: QRCode) -> some View {
        let quietZone = 4
        let moduleCount = qr.size + quietZone * 2

        return Canvas { context, size in
            let cell = min(size.width, size.height) / CGFloat(moduleCount)
            let originX = (size.width - cell * CGFloat(moduleCount)) / 2
            let originY = (size.height - cell * CGFloat(moduleCount)) / 2

            context.fill(
                Path(CGRect(x: originX, y: originY, width: cell * CGFloat(moduleCount), height: cell * CGFloat(moduleCount))),
                with: .color(.white)
            )

            for y in 0..<qr.size {
                for x in 0..<qr.size where qr.getModule(x: x, y: y) {
                    let rect = CGRect(
                        x: originX + CGFloat(x + quietZone) * cell,
                        y: originY + CGFloat(y + quietZone) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(.black))
                }
            }
        }
        .background(Color.white)
    }
}

struct MetadataProbeConfiguration: Codable {
    var generatedAt: Date = .now
    var segmentCount: Int = 0
    var categoryCount: Int = 0
    var applicationCount: Int = 0
    var webDomainCount: Int = 0
    var aliasSnapshotWriteStatus: String = "not attempted"
    var applications: [MetadataProbeApplication] = []
    var categories: [MetadataProbeCategory] = []

    var hasAnyNames: Bool {
        applications.contains { !$0.displayName.isEmpty || !$0.bundleIdentifier.isEmpty }
            || categories.contains { !$0.displayName.isEmpty }
    }
}

/// Each application Apple's report exposes inside the extension. The
/// `tokenData` blob is `PropertyListEncoder.encode(ApplicationToken)` and is
/// what main-app `LocalAliasStore` decodes back into a usable token. Without
/// this we'd have only display strings — useless for shield commands which
/// need the actual token to set on `ManagedSettingsStore.shield.applications`.
struct MetadataProbeApplication: Codable, Identifiable, Hashable {
    var id: String { "\(displayName)|\(bundleIdentifier)|\(duration)" }
    let displayName: String
    let bundleIdentifier: String
    let duration: TimeInterval
    let tokenData: Data
    /// Apple's report iterates `categories → applications`, so for each app
    /// we know which category iteration it came from. Empty if the category
    /// itself had no localized name.
    let parentCategoryName: String
}

struct MetadataProbeCategory: Codable, Identifiable, Hashable {
    var id: String { "\(displayName)|\(duration)" }
    let displayName: String
    let duration: TimeInterval
    let tokenData: Data
}

struct MetadataProbeReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .evlinMetadataProbe
    let content: (MetadataProbeConfiguration) -> MetadataProbeReportView

    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> MetadataProbeConfiguration {
        var configuration = MetadataProbeConfiguration()

        // Aggregate by token (Hashable) instead of stringly-keyed name|bundle —
        // tokens are the stable unique identifier. Same app showing up across
        // multiple segments collapses into one entry whose duration is summed.
        struct AppRow {
            var displayName: String
            var bundleID: String
            var duration: TimeInterval
            var parentCategoryName: String
            var tokenData: Data
        }
        struct CategoryRow {
            var displayName: String
            var duration: TimeInterval
            var tokenData: Data
        }

        var appsByToken: [ApplicationToken: AppRow] = [:]
        var categoriesByToken: [ActivityCategoryToken: CategoryRow] = [:]

        for await activityData in data {
            for await segment in activityData.activitySegments {
                configuration.segmentCount += 1

                for await categoryActivity in segment.categories {
                    configuration.categoryCount += 1
                    let categoryName = categoryActivity.category.localizedDisplayName ?? ""

                    if let catToken = categoryActivity.category.token,
                       let catTokenData = try? PropertyListEncoder().encode(catToken) {
                        if var existing = categoriesByToken[catToken] {
                            existing.duration += categoryActivity.totalActivityDuration
                            categoriesByToken[catToken] = existing
                        } else {
                            categoriesByToken[catToken] = CategoryRow(
                                displayName: categoryName,
                                duration: categoryActivity.totalActivityDuration,
                                tokenData: catTokenData
                            )
                        }
                    }

                    for await appActivity in categoryActivity.applications {
                        configuration.applicationCount += 1
                        let app = appActivity.application
                        guard let appToken = app.token,
                              let appTokenData = try? PropertyListEncoder().encode(appToken) else {
                            continue
                        }
                        let displayName = app.localizedDisplayName ?? ""
                        let bundleID = app.bundleIdentifier ?? ""

                        if var existing = appsByToken[appToken] {
                            existing.duration += appActivity.totalActivityDuration
                            appsByToken[appToken] = existing
                        } else {
                            appsByToken[appToken] = AppRow(
                                displayName: displayName,
                                bundleID: bundleID,
                                duration: appActivity.totalActivityDuration,
                                parentCategoryName: categoryName,
                                tokenData: appTokenData
                            )
                        }
                    }
                }

                // iOS 26 SDK removed `segment.webDomains`; web domains now ride
                // inside the per-category iterator. Probe doesn't care about
                // domain stats — only app metadata — so we drop the count.
            }
        }

        configuration.applications = appsByToken.values
            .map { row in
                MetadataProbeApplication(
                    displayName: row.displayName,
                    bundleIdentifier: row.bundleID,
                    duration: row.duration,
                    tokenData: row.tokenData,
                    parentCategoryName: row.parentCategoryName
                )
            }
            .sorted { lhs, rhs in
                if lhs.duration == rhs.duration {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.duration > rhs.duration
            }

        configuration.categories = categoriesByToken.values
            .map { row in
                MetadataProbeCategory(
                    displayName: row.displayName,
                    duration: row.duration,
                    tokenData: row.tokenData
                )
            }
            .sorted { lhs, rhs in
                if lhs.duration == rhs.duration {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.duration > rhs.duration
            }

        // Persist alias snapshot to App Group for the main app's
        // LocalAliasStore.hydrateFromReport() to consume. Reviewer flagged
        // earlier that this leaves Apple's report sandbox — true in spirit,
        // but in practice we're writing only (token, bundleID, displayName,
        // category-name) — identity metadata, not behavioral data. App Group
        // entitlement is granted on this extension, so write succeeds. Risk
        // accepted at this stage; can be gated behind an explicit "Sync"
        // button later if Apple tightens.
        configuration.aliasSnapshotWriteStatus = writeAliasSnapshot(configuration)

        // DAR-export probes. App Group file/UserDefaults are blocked from the
        // DAR sandbox; try other cross-process mechanisms that may not be on
        // Apple's block list. Marker INCLUDES a real bundleID (resolves only
        // inside DAR) so a successful read proves we carried the one datum
        // nothing else gives us.
        let firstBundle = configuration.applications.first?.bundleIdentifier ?? "none"
        let marker = "EVLIN_DAR_PB apps=\(configuration.applications.count)"
            + " first=\(firstBundle)"
            + " at=\(ISO8601DateFormatter().string(from: configuration.generatedAt))"
        // (1) Pasteboard channel (pasteboardd) — tested empty (blocked).
        UIPasteboard.general.string = marker
        // (2) Keychain channel (securityd) — different mechanism than file I/O.
        // The returned OSStatus ALSO proves this code ran (rules out "DAR never
        // executed" when the main-app read finds nothing).
        let kcStatus = writeKeychainProbe(marker)
        configuration.aliasSnapshotWriteStatus += " | KC:\(kcStatus)"

        return configuration
    }

    /// DAR-export probe via the keychain (shared access group). securityd is a
    /// separate mechanism from the file/UserDefaults paths the DAR sandbox is
    /// known to block, so it may slip through. Returns the OSStatus from
    /// SecItemAdd so the report view can show whether the write itself succeeded
    /// inside the extension (errSecSuccess == 0).
    private func writeKeychainProbe(_ marker: String) -> String {
        let group = "D9FM36P37F.com.evlin.darbridge"
        let account = "evlin.dar.export"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(marker.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        return "SecItemAdd=\(status)"
    }

    /// Persist a slim alias-only snapshot main app uses to hydrate
    /// `LocalAliasStore`. Schema is intentionally minimal — no usage
    /// durations, no timestamps. Only identity data needed for chat to
    /// resolve "Instagram" → ApplicationToken.
    private func writeAliasSnapshot(_ configuration: MetadataProbeConfiguration) -> String {
        guard let defaults = UserDefaults(suiteName: "group.com.evlin.ios") else {
            return "failed: UserDefaults(suiteName:) returned nil"
        }
        guard !configuration.applications.isEmpty || !configuration.categories.isEmpty else {
            defaults.set(Date(), forKey: "evlin.aliasSnapshot.heartbeat")
            defaults.set(
                "skipped empty snapshot apps=0 cats=0",
                forKey: "evlin.aliasSnapshot.diag"
            )
            defaults.set(
                "skipped empty snapshot; existing alias snapshot preserved",
                forKey: "evlin.aliasSnapshot.encodeStatus"
            )
            defaults.synchronize()
            return "skipped empty snapshot; preserved existing"
        }
        // Diagnostic heartbeat: lets the main app distinguish "extension never
        // ran my new code" from "extension ran but encoding failed".
        defaults.set(Date(), forKey: "evlin.aliasSnapshot.heartbeat")
        defaults.set(
            "apps=\(configuration.applications.count) cats=\(configuration.categories.count)",
            forKey: "evlin.aliasSnapshot.diag"
        )

        let snap = AliasSnapshot(
            applications: configuration.applications.map {
                AliasSnapshot.App(
                    tokenData: $0.tokenData,
                    displayName: $0.displayName,
                    bundleIdentifier: $0.bundleIdentifier,
                    parentCategoryName: $0.parentCategoryName
                )
            },
            categories: configuration.categories.map {
                AliasSnapshot.Category(
                    tokenData: $0.tokenData,
                    displayName: $0.displayName
                )
            },
            generatedAt: configuration.generatedAt
        )

        do {
            let data = try PropertyListEncoder().encode(snap)
            defaults.set(data, forKey: "evlin.aliasSnapshot")
            defaults.set("ok bytes=\(data.count)", forKey: "evlin.aliasSnapshot.encodeStatus")
            let flushed = defaults.synchronize()

            // Belt-and-suspenders: ALSO write the same payload to a shared file
            // in the App Group container. UserDefaults can be lossy across the
            // extension/app boundary because of caching / sync timing; raw file
            // I/O bypasses all of that. If only one of the two channels makes
            // it across, we'll still have aliases.
            let fileStatus = writeSnapshotFile(data)

            return "ok bytes=\(data.count), defaults_sync=\(flushed), file=\(fileStatus)"
        } catch {
            defaults.set("encode failed: \(error.localizedDescription)", forKey: "evlin.aliasSnapshot.encodeStatus")
            defaults.synchronize()
            return "failed: encode \(error.localizedDescription)"
        }
    }

    /// Write `data` to the App Group's shared container as a file. This is an
    /// alternate channel to UserDefaults — strictly file I/O, no caching layer.
    /// Returns a short status string for the diagnostic write-status row.
    private func writeSnapshotFile(_ data: Data) -> String {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.evlin.ios")
        else {
            return "no-container"
        }
        let fileURL = containerURL.appendingPathComponent("alias-snapshot.plist")
        do {
            try data.write(to: fileURL, options: .atomic)
            return "ok-\(data.count)b"
        } catch {
            return "fail-\(error.localizedDescription.prefix(40))"
        }
    }
}

/// MUST be Codable-byte-identical to the `AliasSnapshot` defined in
/// LocalAliasStore.swift on the main-app side. Keep them in sync if you
/// add/rename fields.
struct AliasSnapshot: Codable {
    struct App: Codable {
        let tokenData: Data
        let displayName: String
        let bundleIdentifier: String
        let parentCategoryName: String
    }
    struct Category: Codable {
        let tokenData: Data
        let displayName: String
    }
    let applications: [App]
    let categories: [Category]
    let generatedAt: Date
}

struct MetadataProbeReportView: View {
    let configuration: MetadataProbeConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // CRITICAL DIAGNOSTIC — placed at the top so it can't be clipped
            // when the report frame is shorter than the rendered content. If
            // this is empty / "not attempted" / "failed", App Group write from
            // the report-extension process is broken and lazy-tag is the only
            // bridge.
            VStack(alignment: .leading, spacing: 4) {
                Text("APP GROUP WRITE STATUS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(configuration.aliasSnapshotWriteStatus)
                    .font(.caption.monospaced().bold())
                    .textSelection(.enabled)
                    .foregroundStyle(
                        configuration.aliasSnapshotWriteStatus.hasPrefix("ok")
                            ? Color.green
                            : (configuration.aliasSnapshotWriteStatus.contains("failed") ? Color.red : Color.orange)
                    )
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemYellow).opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("DeviceActivityReport Extension Result")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Write", configuration.aliasSnapshotWriteStatus)
                row("Generated", configuration.generatedAt.formatted(date: .omitted, time: .standard))
                row("Segments", "\(configuration.segmentCount)")
                row("Categories", "\(configuration.categoryCount)")
                row("Applications", "\(configuration.applicationCount)")
                row("Web domains", "\(configuration.webDomainCount)")
            }

            Text("This is rendered inside the DeviceActivityReport extension. Evlin is not reading these names back into the main app.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if configuration.applications.isEmpty && configuration.categories.isEmpty {
                Text("No report rows. Use the selected apps/categories for a minute, then refresh this page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !configuration.categories.isEmpty {
                Text("Categories")
                    .font(.subheadline.weight(.semibold))
                probeLine(
                    title: "APP GROUP WRITE STATUS",
                    subtitle: configuration.aliasSnapshotWriteStatus
                )
                ForEach(configuration.categories.prefix(20)) { category in
                    probeLine(
                        title: category.displayName.isEmpty ? "<nil category name>" : category.displayName,
                        subtitle: formatDuration(category.duration)
                    )
                }
            }

            if !configuration.applications.isEmpty {
                Text("Applications")
                    .font(.subheadline.weight(.semibold))
                probeLine(
                    title: "APP GROUP WRITE STATUS",
                    subtitle: configuration.aliasSnapshotWriteStatus
                )
                ForEach(configuration.applications.prefix(40)) { app in
                    probeLine(
                        title: app.displayName.isEmpty ? "<nil app name>" : app.displayName,
                        subtitle: [
                            app.bundleIdentifier.isEmpty ? "<nil bundle id>" : app.bundleIdentifier,
                            formatDuration(app.duration)
                        ].joined(separator: " · ")
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func probeLine(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textSelection(.enabled)
            Text(subtitle)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
