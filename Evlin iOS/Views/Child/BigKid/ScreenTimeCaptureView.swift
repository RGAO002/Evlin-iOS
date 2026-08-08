// Evlin iOS/Evlin iOS/Views/Child/BigKid/ScreenTimeCaptureView.swift
//
// Production "Enable Screen-Time Tracking" capture flow (Task B3 finish).
//
// This view is reachable from BigKidHomeView when the all-category measurement
// selection is missing from EarnedTimeStore. It mirrors the working pattern in
// WholeDeviceThresholdProbeView (DEBUG), but persists the result to
// EarnedTimeStore.shared via saveMeasurementSelection(), then explicitly runs
// the same v2 policy recovery used by the poller and onboarding flow.
//
// Gate: only shown when EarnedTimeStore.shared.measurementSelection == nil.
// Once captured, the card disappears from BigKidHomeView automatically
// (the parent observes EarnedTimeStore readiness state via @State capture).
//
// Screen Time authorization: the FamilyActivityPicker requires
// AuthorizationCenter.shared.authorizationStatus == .approved. If not
// authorized, this view explains what to do instead of crashing.

import FamilyControls
import SwiftUI

struct ScreenTimeCaptureView: View {
    /// Called when the selection was successfully saved.
    var onDone: () -> Void = {}

    @StateObject private var capture = TrackingSelectionCapture()
    @State private var pickerShown = false

    var body: some View {
        EvKidCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                // Header row
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(EvlinKidColors.green100)
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(EvlinKidColors.green700)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("SET UP SCREEN-TIME TRACKING")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(EvlinKidColors.green700)
                        Text("Enable earned screen time")
                            .font(.system(size: 16, weight: .heavy))
                            .tracking(EvlinKidMetrics.Letter.body)
                            .foregroundStyle(EvlinKidColors.ink)
                        Text("One-time setup — takes 10 seconds")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(EvlinKidColors.ink3)
                    }
                }

                // Explanation
                Text("Tap the button below and choose All Apps & Categories so Evlin can measure how much screen time you've earned today.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EvlinKidColors.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                if capture.state == .needsSelection {
                    Text("Choose All Apps & Categories before closing this step.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(EvlinKidColors.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if capture.state == .notAuthorized {
                    Text("Screen Time isn't authorized yet. Ask a parent to complete the Screen Time setup step first.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(EvlinKidColors.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // CTA button
                Button {
                    openPicker()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 16, weight: .semibold))
                        Text(capture.state == .saved ? "Done! Tracking enabled" : "Select all categories")
                            .font(.system(size: 15, weight: .heavy))
                            .tracking(EvlinKidMetrics.Letter.body)
                    }
                    .foregroundStyle(capture.state == .saved ? EvlinKidColors.green700 : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(capture.state == .saved ? EvlinKidColors.green100 : EvlinKidColors.green600)
                    )
                }
                .buttonStyle(.plain)
                .disabled(capture.state == .saved)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: capture.state == .saved ? [] : [4]))
                .foregroundStyle(EvlinKidColors.green300)
        )
        .familyActivityPicker(isPresented: $pickerShown, selection: $capture.selection)
        .onChange(of: pickerShown) { _, isOpen in
            // Picker was dismissed (closed) — save if the user picked anything
            if !isOpen {
                saveIfReady()
            }
        }
    }

    private func openPicker() {
        // Check authorization before opening the picker to avoid a crash on an
        // unauthorized device (should not happen in production — Screen Time
        // auth is acquired during child onboarding — but guard defensively).
        let approved = AuthorizationCenter.shared.authorizationStatus == .approved
        pickerShown = capture.requestPicker(authorized: approved)
    }

    private func saveIfReady() {
        Task {
            await capture.commit {
                guard let raw = UserDefaults.standard.string(
                    forKey: DeviceIdentity.childKey
                ),
                let childID = UUID(uuidString: raw),
                let baseURL = URL(string: APIClient.currentBaseURL)
                else { return }
                _ = await MeteringPolicyRefresh.now(
                    childDeviceID: childID,
                    baseURL: baseURL
                )
            }
            guard capture.state == .saved else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                onDone()
            }
        }
    }
}

#if DEBUG
#Preview("Needs setup") {
    ScreenTimeCaptureView()
        .padding()
        .background(EvlinKidColors.surface2.ignoresSafeArea())
}
#endif
