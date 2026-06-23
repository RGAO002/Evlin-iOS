// Evlin iOS/Evlin iOS/Views/Debug/EarnedTimeMeasurementCaptureView.swift
//
// One-time capture of the all-category FamilyActivitySelection needed by the
// earned screen-time measurement subsystem (Task B3 / §5.5).
//
// Why a manual picker capture is required: Apple provides no programmatic
// "select all categories" API on the kid device at runtime. The only way to
// obtain a valid opaque token set for whole-device measurement is via
// FamilyActivityPicker. This view is the minimal v1 entry point — full
// onboarding placement is a later UX task.
//
// Pattern: mirrors WholeDeviceThresholdProbeView (committed 90eae49) which
// already proved that `FamilyActivitySelection(includeEntireCategory: true)` +
// `.familyActivityPicker(...)` works for whole-device category coverage.
//
// Repair path: if `EarnedTimeStore.shared.measurementSelection` is nil (e.g.
// after an account reset or first install), the "Capture / Repair" button
// re-opens the picker.
#if DEBUG
import DeviceActivity
import FamilyControls
import SwiftUI

struct EarnedTimeMeasurementCaptureView: View {
    /// Pre-seeded with includeEntireCategory so the picker opens with all
    /// categories already highlighted — the user just confirms.
    @State private var selection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var pickerShown = false
    @State private var saveStatus = ""

    private let store = EarnedTimeStore.shared

    var body: some View {
        List {
            Section {
                Text(
                    """
                    Captures the all-category FamilyActivitySelection required by the earned screen-time measurement ladder (B3). Open the picker, select ALL categories (no individual apps needed), then save. This is a one-time operation per device; use "Repair" if the store entry is missing.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Measurement selection", value: store.measurementSelection != nil ? "Saved" : "Missing")
                LabeledContent("Locked-set ID", value: store.lockedSetID ?? "—")
                LabeledContent("Ready to measure", value: store.isEarnedTimeReady ? "Yes" : "No")
            }

            Section("1 · Capture all-category selection") {
                Button {
                    pickerShown = true
                } label: {
                    Label(
                        store.measurementSelection == nil ? "Capture (first time)" : "Repair — re-open picker",
                        systemImage: store.measurementSelection == nil ? "plus.circle" : "arrow.triangle.2.circlepath"
                    )
                }
                LabeledContent("Categories in current picker state", value: "\(selection.categoryTokens.count)")
                LabeledContent("Apps individually selected", value: "\(selection.applicationTokens.count)")
            }

            Section("2 · Save to App Group store") {
                Button {
                    saveSelection()
                } label: {
                    Label("Save selection", systemImage: "square.and.arrow.down")
                }
                .disabled(selection.categoryTokens.isEmpty && selection.applicationTokens.isEmpty)
                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(saveStatus.hasPrefix("Saved") ? .green : .orange)
                        .textSelection(.enabled)
                }
            }

            Section("Dev — clear store (testing)") {
                Button(role: .destructive) {
                    store.removeAll()
                    saveStatus = "Cleared all earned-time store keys."
                } label: {
                    Label("Clear earned-time store", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Earned time — measurement capture")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $pickerShown, selection: $selection)
    }

    private func saveSelection() {
        store.saveMeasurementSelection(selection)
        saveStatus = "Saved — \(selection.categoryTokens.count) category token(s), \(selection.applicationTokens.count) app token(s). isEarnedTimeReady: \(store.isEarnedTimeReady)."
    }
}
#endif
