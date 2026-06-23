// Evlin iOS/Evlin iOS/Views/Debug/WholeDeviceThresholdProbeView.swift
//
// DEBUG-only spike: can a DeviceActivityEvent threshold measure WHOLE-DEVICE
// usage? i.e. if we arm on ALL CATEGORIES (and NO individual apps), does the
// threshold fire when the user opens an app that was never individually
// selected? If yes, category-level selection captures the whole device —
// including unselected apps — which is the foundation for the "total screen
// time" estimate.
//
// Why this won't hit the DAR sandbox wall: the threshold callback runs in the
// MONITOR extension (DeviceActivityMonitorExtension.eventDidReachThreshold),
// which CAN write the App Group. So the "did it fire" marker reliably crosses
// back to the app — unlike the report extension, which can't write anywhere.
//
// How to run:
//   1. Open the picker, tap the top-level "select all" so ALL categories are
//      selected. Do NOT individually select apps — we arm on categoryTokens
//      only, so a fire can ONLY come from category-level capture.
//   2. Arm (threshold 1 min, daily schedule).
//   3. Use an app you never individually selected for ~1-2 min.
//   4. Check fired. ✅ = whole-device measurement works.
#if DEBUG
import DeviceActivity
import FamilyControls
import SwiftUI

struct WholeDeviceThresholdProbeView: View {
    @State private var selection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var pickerShown = false
    @State private var armStatus = ""
    @State private var fireStatus = ""

    private let center = DeviceActivityCenter()
    private let activityName = DeviceActivityName("evlin.test.wholeDevice")
    private let eventName = DeviceActivityEvent.Name("evlin.test.wholeDevice")
    private let group = "group.com.evlin.ios"

    var body: some View {
        List {
            Section {
                Text(
                    """
                    Verifies whether a DeviceActivityEvent threshold can measure WHOLE-DEVICE usage. Arm on ALL CATEGORIES (no individual apps), then use an app you never selected — if the threshold fires, category-level selection captures the whole device.

                    The fire signal comes from the MONITOR extension (which CAN write the App Group), so it won't hit the DAR sandbox wall.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("1 · Pick ALL categories (no individual apps)") {
                Button {
                    pickerShown = true
                } label: {
                    Label("Open picker — select all categories", systemImage: "square.grid.2x2")
                }
                LabeledContent("Categories selected", value: "\(selection.categoryTokens.count)")
                LabeledContent("Apps individually selected", value: "\(selection.applicationTokens.count)")
                if !selection.applicationTokens.isEmpty {
                    Text("For a clean result, deselect individual apps — we arm on categories only, but selecting categories alone removes all doubt.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Section("2 · Arm the threshold (1 min, categories only)") {
                Button {
                    arm()
                } label: {
                    Label("Arm whole-device threshold", systemImage: "bolt.badge.clock")
                }
                .disabled(selection.categoryTokens.isEmpty)
                if !armStatus.isEmpty {
                    Text(armStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(armStatus.hasPrefix("✅") ? .green : .orange)
                        .textSelection(.enabled)
                }
            }

            Section("3 · Use an UNSELECTED app ~1-2 min, then check") {
                Button {
                    fireStatus = checkFired()
                } label: {
                    Label("Check if it fired", systemImage: "checkmark.circle")
                }
                if !fireStatus.isEmpty {
                    Text(fireStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(fireStatus.hasPrefix("✅") ? .green : .orange)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button(role: .destructive) {
                    stopAndClear()
                } label: {
                    Label("Stop & clear test", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Whole-device threshold")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $pickerShown, selection: $selection)
    }

    private func arm() {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        // Arm on categories ONLY (ignore any individually-selected apps) so a
        // fire can only be attributed to category-level whole-device capture.
        let event = DeviceActivityEvent(
            applications: [],
            categories: selection.categoryTokens,
            webDomains: [],
            threshold: DateComponents(minute: 1)
        )
        // Clear any prior fire marker so a stale one isn't mistaken for new.
        let d = UserDefaults(suiteName: group)
        ["firedAt", "count", "diag"].forEach { d?.removeObject(forKey: "evlin.test.wholeDevice.\($0)") }
        d?.set(Date(), forKey: "evlin.test.wholeDevice.armedAt")
        do {
            try center.startMonitoring(activityName, during: schedule, events: [eventName: event])
            armStatus = "✅ armed on \(selection.categoryTokens.count) categories, threshold 1 min. Now use an unselected app. (May fire quickly if there is already usage today.)"
        } catch {
            armStatus = "✗ startMonitoring failed: \(error.localizedDescription)"
        }
    }

    private func checkFired() -> String {
        let d = UserDefaults(suiteName: group)
        let armedAt = d?.object(forKey: "evlin.test.wholeDevice.armedAt") as? Date
        guard let firedAt = d?.object(forKey: "evlin.test.wholeDevice.firedAt") as? Date else {
            let armedStr = armedAt.map { " (armed \($0.formatted(date: .omitted, time: .standard)))" } ?? ""
            return "✗ not fired yet\(armedStr) — use an unselected app 1-2 min, wait for Apple's aggregation lag, then check again."
        }
        let count = d?.integer(forKey: "evlin.test.wholeDevice.count") ?? 0
        let diag = d?.string(forKey: "evlin.test.wholeDevice.diag") ?? ""
        let elapsed = armedAt.map { "  (\(Int(firedAt.timeIntervalSince($0)))s after arming)" } ?? ""
        return "✅ FIRED \(count)× — whole-device threshold works!\nfired @ \(firedAt.formatted(date: .omitted, time: .standard))\(elapsed)\n\(diag)"
    }

    private func stopAndClear() {
        center.stopMonitoring([activityName])
        let d = UserDefaults(suiteName: group)
        ["firedAt", "count", "diag", "armedAt"].forEach { d?.removeObject(forKey: "evlin.test.wholeDevice.\($0)") }
        armStatus = ""
        fireStatus = "Stopped & cleared."
    }
}
#endif
