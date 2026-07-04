import SwiftUI

// B9 cascade confirmation, redesigned. Shared by ProfileView (daily pool)
// and DeviceAppsSheet (device cap).
//
// Semantics: applying TODAY is the normal case and the primary action —
// the pool/cap change takes effect immediately (a reduction below today's
// usage locks right away per Fix 8). "Apply tomorrow" is the gentle
// alternative that defers to midnight so today's sessions aren't cut short.

struct EarnedCascadeConfirmSheet: View {
    let result: EarnedCascadeDecision.Result
    /// Summary line shown above the options (and in place of an empty
    /// affected-items list). Callers pass pool- or cap-specific copy.
    var summary: String = "Lowering the daily pool may reduce device and app limits."
    /// Called with "today" or "tomorrow" when the parent picks an option.
    var onApply: (_ effective: String) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.evPrimaryContainer)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.evPrimary)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm changes")
                        .font(.custom("Inter", size: 18).weight(.bold))
                        .foregroundStyle(Color.evOnSurface)
                    Text(summary)
                        .font(.custom("Inter", size: 13))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 28)

            // Affected items (only when the cascade enumerated any)
            if !result.affectedDevices.isEmpty || !result.affectedApps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("THESE LIMITS WILL CHANGE")
                        .font(.custom("Inter", size: 11).weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                    VStack(alignment: .leading, spacing: 6) {
                        // Not `description` — that copy hardcodes "tomorrow",
                        // which is wrong for the apply-now option.
                        ForEach(result.affectedDevices, id: \.deviceID) { dev in
                            affectedRow(
                                icon: "iphone",
                                text: "\(dev.name)  \(dev.currentCapMinutes)m → \(dev.newCapMinutes)m")
                        }
                        ForEach(result.affectedApps, id: \.bundleID) { app in
                            affectedRow(
                                icon: "app.badge",
                                text: "\(app.name)  \(app.currentBudgetMinutes)m → \(app.newBudgetMinutes)m")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.evSurfaceContainerLow)
                    )
                }
                .padding(.top, 18)
            }

            // Options
            VStack(spacing: 10) {
                optionButton(
                    title: "Apply now",
                    caption: "Updates today's limits right away",
                    filled: true
                ) {
                    onApply("today")
                    dismiss()
                }
                optionButton(
                    title: "Apply tomorrow",
                    caption: "Starts at midnight — today's sessions aren't cut short",
                    filled: false
                ) {
                    onApply("tomorrow")
                    dismiss()
                }
            }
            .padding(.top, 22)

            // Cancel
            Button {
                onCancel()
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.custom("Inter", size: 15).weight(.medium))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .background(Color.evSurface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func affectedRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 18)
            Text(text)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionButton(
        title: String,
        caption: String,
        filled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.custom("Inter", size: 16).weight(.semibold))
                    .foregroundStyle(filled ? Color.evOnPrimary : Color.evPrimary)
                Text(caption)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(filled ? Color.evOnPrimary.opacity(0.75) : Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(filled ? Color.evPrimary : Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(filled ? Color.clear : Color.evOutlineVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("No enumerated items") {
    Color.evSurfaceDim.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            EarnedCascadeConfirmSheet(
                result: EarnedCascadeDecision.Result(
                    needsConfirmation: true,
                    affectedDevices: [],
                    affectedApps: [],
                    defaultAction: .applyTomorrow)
            )
        }
}
#endif
