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
                Text(detail)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(locked ? Color.evError : Color.evSecondary)
                    .frame(width: 6, height: 6)
                Text(locked ? "LOCKED" : "ACTIVE")
                    .font(.custom("Inter", size: 9).weight(.heavy))
                    .tracking(1.3)
                    .foregroundStyle(locked ? Color.evError : Color.evSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(locked ? Color.evErrorContainer : Color.evSecondaryContainer)
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
