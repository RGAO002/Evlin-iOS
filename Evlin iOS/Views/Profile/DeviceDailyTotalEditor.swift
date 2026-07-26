import SwiftUI

/// Sheet for the per-device daily total, presented from the pencil on the
/// "DEVICE DAILY TOTAL" card. Deliberately the same shape as
/// `DailyScreenTimeEditor` — a continuous slider with a large live readout —
/// because a parent setting two related limits should not meet two different
/// controls.
///
/// The one thing it adds over the screen-time editor is the ceiling: a device
/// may never be allowed more than the family's shared pool (the backend returns
/// 422 for `cap > pool`), so the slider simply cannot travel there. The pool is
/// drawn on the track's right edge, which makes "this device / of the shared
/// total" legible while dragging instead of only after saving.
///
/// Saving routes back through `saveDeviceCap`, so the cascade-confirm gate for
/// lowering a cap below an existing app limit still runs exactly as it did for
/// the preset chips this replaces.
struct DeviceDailyTotalEditor: View {
    /// Current device cap in minutes; `nil` when the device has never had one.
    let currentMinutes: Int?
    /// The family's shared daily pool — the hard ceiling for this device.
    let poolMinutes: Int
    /// Called on Save with the chosen value.
    var onSave: (Int) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Double = 0

    /// The pool, but never past the product maximum. A pool set beyond it is
    /// only reachable outside the parent UI (we set one to 4h while testing),
    /// and a test value must not widen a control the parent uses.
    private var ceilingMinutes: Int { EarnedLimitRange.ceiling(poolMinutes: poolMinutes) }
    /// 15 minutes, or the ceiling when the ceiling is smaller — a slider whose
    /// lower bound exceeds its upper bound traps at runtime.
    private var lowerBound: Double {
        Double(min(EarnedLimitRange.minimumMinutes, ceilingMinutes))
    }
    private var upperBound: Double { Double(ceilingMinutes) }
    /// A degenerate pool leaves nothing to choose between; show the readout and
    /// let the parent save the only legal value rather than a broken slider.
    private var hasRange: Bool { upperBound > lowerBound }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.evSurfaceContainerLow
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        Text("DEVICE DAILY TOTAL")
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .tracking(1.4)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                            .padding(.horizontal, 4)

                        VStack(spacing: 20) {
                            HStack(alignment: .lastTextBaseline, spacing: 6) {
                                Text(DeviceAppsMockData.formatLimit(Int(minutes)))
                                    .font(.custom("Manrope", size: 48).weight(.heavy))
                                    .tracking(-0.96)
                                    .foregroundStyle(Color.evPrimary)
                                Text("/ of \(DeviceAppsMockData.formatLimit(poolMinutes)) shared")
                                    .font(.custom("Inter", size: 13))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)

                            if hasRange {
                                Slider(
                                    value: $minutes,
                                    in: lowerBound...upperBound,
                                    step: Double(EarnedLimitRange.stepMinutes)
                                )
                                .tint(Color.evPrimary)

                                HStack {
                                    Text(DeviceAppsMockData.formatLimit(Int(lowerBound)))
                                        .font(.custom("Inter", size: 11))
                                        .foregroundStyle(Color.evOnSurfaceVariant)
                                    Spacer()
                                    // Say WHY it stops here. When the pool is
                                    // the binding constraint that is worth
                                    // naming; at the product maximum the number
                                    // speaks for itself.
                                    Text(ceilingLabel)
                                        .font(.custom("Inter", size: 11))
                                        .foregroundStyle(Color.evOnSurfaceVariant)
                                }
                            }

                            Text(caption)
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

                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                                .padding(.top, 2)
                            Text("This device can never be allowed more than the shared daily pool.")
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
            .navigationTitle("Device Daily Total")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.evSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
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
            minutes = Self.initialValue(
                current: currentMinutes,
                poolMinutes: poolMinutes
            )
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var ceilingLabel: String {
        let ceiling = DeviceAppsMockData.formatLimit(ceilingMinutes)
        return poolMinutes < EarnedLimitRange.maximumMinutes ? "\(ceiling) (pool)" : ceiling
    }

    private var caption: String {
        hasRange
            ? "The most this device may use out of the shared pool each day."
            : "The shared pool is \(DeviceAppsMockData.formatLimit(poolMinutes)), so that is all this device can have."
    }

    /// Where the handle starts. Pure and `static` so the clamping is unit
    /// testable: a cap saved before the pool was lowered — or before the
    /// ceiling was tightened — can legitimately sit ABOVE today's range, and
    /// `Slider` traps when its value is out of range.
    static func initialValue(current: Int?, poolMinutes: Int) -> Double {
        Double(
            EarnedLimitRange.clamped(
                current ?? poolMinutes,
                poolMinutes: poolMinutes
            )
        )
    }
}

#if DEBUG
#Preview("Device Daily Total") {
    DeviceDailyTotalEditor(currentMinutes: 120, poolMinutes: 240) { newValue in
        print("Saved: \(newValue) min")
    }
}
#endif
