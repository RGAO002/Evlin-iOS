import SwiftUI

/// Per-device row inside the Enrolled Devices card. Mirrors HTML 666-728:
/// top row = icon + name + detail + status pill + chevron;
/// indented bottom row = "Screen time remaining" + colored value + 5px progress bar.
struct DeviceRow: View {
    let iconSystemName: String
    let name: String
    let detail: String
    var locked: Bool = false
    /// `timeLeft` / `timePct` are taken from the child's overall budget.
    /// When nil the bottom row is hidden (legacy callers).
    var timeLeft: String? = nil
    var timePct: Double? = nil
    var meteringReady: Bool = false
    var isLast: Bool = false
    var onPress: () -> Void = {}

    private var barColor: Color {
        if locked { return Color.evError }
        return Color.evTimeRemaining(timePct ?? 1.0)
    }

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 10) {
                topRow
                if let timeLeft, let timePct {
                    progressRow(timeLeft: timeLeft, timePct: timePct)
                        .padding(.leading, 54)        // align with name (40 icon + 14 gap)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .overlay(
                Rectangle().fill(Color.evOutlineVariant.opacity(isLast ? 0 : 0.4))
                    .frame(height: 1),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    /// One pill carries the whole story, so the name/detail column keeps its
    /// width (the separate tick + pill pair used to wrap "iPad (10th gen) ·
    /// iOS 26" onto two lines):
    /// - LOCKED   (red)   — a shield is covering this device
    /// - TRACKING (green) — armed, and the device's watchdog attested it
    /// - SYNCING  (grey)  — no attestation yet (fresh arm, app closed, …)
    private var statusText: String {
        if locked { return "LOCKED" }
        return meteringReady ? "ACTIVE" : "SYNCING"
    }

    private var statusColor: Color {
        if locked { return Color.evError }
        return meteringReady ? Color.evSecondary : Color.evOnSurfaceVariant
    }

    private var statusBackground: Color {
        if locked { return Color.evErrorContainer }
        return meteringReady ? Color.evSecondaryContainer : Color.evSurfaceContainerHigh
    }

    private var topRow: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
                Image(systemName: iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.custom("Manrope", size: 14).weight(.bold))
                    .foregroundStyle(Color.evPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.custom("Inter", size: 9).weight(.heavy))
                    .tracking(1.3)
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(statusBackground))
            .fixedSize()
            .accessibilityLabel(
                locked
                    ? "Device locked"
                    : (meteringReady
                        ? "Screen Time tracking confirmed"
                        : "Screen Time tracking not yet confirmed")
            )

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.evOutline)
        }
    }

    private func progressRow(timeLeft: String, timePct: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Screen time remaining")
                    .font(.custom("Inter", size: 11))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Spacer()
                Text(locked ? "None" : timeLeft)
                    .font(.custom("Manrope", size: 12).weight(.heavy))
                    .foregroundStyle(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.evSurfaceContainerHigh)
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * (locked ? 0 : timePct)))
                }
            }
            .frame(height: 5)
        }
    }
}
