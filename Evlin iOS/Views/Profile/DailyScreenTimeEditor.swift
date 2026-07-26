import SwiftUI

/// Sheet presented when the parent taps the pencil on the "Daily Screen Time"
/// rule row. Shows a continuous slider (15–180 min, step 5) and saves the
/// selection via an `onSave` closure. Local-only — no backend, no enforcement.
struct DailyScreenTimeEditor: View {
    /// The current per-child limit in minutes (pre-loaded from UserDefaults).
    let currentMinutes: Int
    /// Called on Save with the new value in minutes.
    var onSave: (Int) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Double = 120

    private static let bounds =
        Double(EarnedLimitRange.minimumMinutes)...Double(EarnedLimitRange.maximumMinutes)

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.evSurfaceContainerLow
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        // Section label
                        Text("DAILY LIMIT")
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .tracking(1.4)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                            .padding(.horizontal, 4)

                        // Live readout + slider card
                        VStack(spacing: 20) {
                            // Large live readout
                            Text(ProfileMockData.formatLimit(Int(minutes)))
                                .font(.custom("Manrope", size: 48).weight(.heavy))
                                .tracking(-0.96)
                                .foregroundStyle(Color.evPrimary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 8)

                            // Slider — bounds come from `EarnedLimitRange` so
                            // this editor and the device-total editor cannot
                            // drift apart, and neither can drift from the
                            // backend's `_POOL_OPTIONS`, which rejects anything
                            // outside it.
                            Slider(
                                value: $minutes,
                                in: Self.bounds,
                                step: Double(EarnedLimitRange.stepMinutes)
                            )
                            .tint(Color.evPrimary)

                            // Range labels
                            HStack {
                                Text(ProfileMockData.formatLimit(EarnedLimitRange.minimumMinutes))
                                    .font(.custom("Inter", size: 11))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                                Spacer()
                                Text(ProfileMockData.formatLimit(EarnedLimitRange.maximumMinutes))
                                    .font(.custom("Inter", size: 11))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }

                            // Caption
                            Text("Total screen time allowed each day. Currently \(ProfileMockData.formatLimit(Int(minutes))).")
                                .font(.custom("Inter", size: 13))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 8)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.evSurfaceContainerLowest)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                        )

                        // Locked notice
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                                .padding(.top, 2)
                            Text("Daily Screen Time is your core rule, so it can't be removed.")
                                .font(.custom("Inter", size: 13))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.evSurfaceContainer)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.evOutlineVariant.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 60)
                }
            }
            .navigationTitle("Daily Screen Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.evSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.custom("Inter", size: 17))
                    .foregroundStyle(Color.evPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(Int(minutes))
                        dismiss()
                    }
                    .font(.custom("Inter", size: 17).weight(.semibold))
                    .foregroundStyle(Color.evPrimary)
                }
            }
        }
        .onAppear {
            // Clamped, not assigned: a stored value outside the range (an older
            // build, or a value written by something other than this editor)
            // makes `Slider` trap on a binding it cannot represent.
            minutes = Double(
                EarnedLimitRange.clamped(
                    currentMinutes,
                    poolMinutes: EarnedLimitRange.maximumMinutes
                )
            )
        }
        // Half-height sheet (the slider + notice fit comfortably); draggable
        // up to full if needed.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Daily Screen Time Editor") {
    DailyScreenTimeEditor(currentMinutes: 120) { newMinutes in
        print("Saved: \(newMinutes) min")
    }
}
#endif
