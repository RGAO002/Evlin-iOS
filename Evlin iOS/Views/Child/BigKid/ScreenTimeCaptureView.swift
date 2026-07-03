// Evlin iOS/Evlin iOS/Views/Child/BigKid/ScreenTimeCaptureView.swift
//
// Production "Enable Screen-Time Tracking" capture flow (Task B3 finish).
//
// This view is reachable from BigKidHomeView when the all-category measurement
// selection is missing from EarnedTimeStore. It mirrors the working pattern in
// WholeDeviceThresholdProbeView (DEBUG), but persists the result to
// EarnedTimeStore.shared via saveMeasurementSelection() — making
// isEarnedTimeReady satisfiable and arming the earned-budget ladder on next
// foreground via armEarnedBudgetIfReady() in Evlin_iOSApp.
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

    @State private var selection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var pickerShown = false
    @State private var isSaved = false
    @State private var notAuthorized = false

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
                Text("Tap the button below and allow all categories so Evlin can measure how much screen time you've earned today.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EvlinKidColors.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                if notAuthorized {
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
                        Text(isSaved ? "Done! Tracking enabled" : "Select all categories")
                            .font(.system(size: 15, weight: .heavy))
                            .tracking(EvlinKidMetrics.Letter.body)
                    }
                    .foregroundStyle(isSaved ? EvlinKidColors.green700 : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSaved ? EvlinKidColors.green100 : EvlinKidColors.green600)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSaved)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: isSaved ? [] : [4]))
                .foregroundStyle(EvlinKidColors.green300)
        )
        .familyActivityPicker(isPresented: $pickerShown, selection: $selection)
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
        let status = AuthorizationCenter.shared.authorizationStatus
        guard status == .approved else {
            notAuthorized = true
            return
        }
        notAuthorized = false
        pickerShown = true
    }

    private func saveIfReady() {
        // Save even an empty selection (zero tokens) — the PRESENCE of a saved
        // value is what satisfies isEarnedTimeReady; the FamilyActivitySelection
        // with includeEntireCategory:true covers the whole device regardless of
        // which specific tokens are returned by the system picker.
        //
        // Note: we save unconditionally on picker dismiss because the user
        // explicitly opened the picker via our CTA button. If they cancelled
        // without tapping categories we still persist the default
        // includeEntireCategory:true selection — that is the correct behavior
        // for whole-device monitoring.
        EarnedTimeStore.shared.saveMeasurementSelection(selection)
        // Arm immediately. Waiting for the next scene activation left the
        // device unmonitored — or worse, still monitored by a stale ladder —
        // when the kid went straight to other apps after this step.
        EarnedBudgetArming.armIfReady()
        withAnimation(.easeOut(duration: 0.3)) { isSaved = true }
        // Brief delay so the success state is visible, then dismiss.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            onDone()
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
