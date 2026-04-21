import SwiftUI

// MARK: - Sticky header with kicker, back affordance, trailing slot
// Mirrors Esen's GlassHeader from frontend_for_app_evlin/ui.jsx lines 23-70.

struct GlassmorphicHeader<Trailing: View>: View {
    let title: String
    var kicker: String? = nil
    var onBack: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.evPrimary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let kicker {
                    Text(kicker.uppercased())
                        .font(.custom("Inter", size: 10).weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.custom("Manrope", size: 19).weight(.heavy))
                        .tracking(-0.15)
                        .foregroundStyle(Color.evPrimary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            trailing()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 56)
        .padding(.vertical, 6)
        .background(
            Color.evSurface.opacity(0.99)
                .background(.ultraThinMaterial)
        )
        .overlay(
            Rectangle()
                .fill(Color.evOutlineVariant)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// Convenience init — no trailing content
extension GlassmorphicHeader where Trailing == EmptyView {
    init(title: String, kicker: String? = nil, onBack: (() -> Void)? = nil) {
        self.init(title: title, kicker: kicker, onBack: onBack, trailing: { EmptyView() })
    }
}

// MARK: - Standard header icon button (40x40 circular, optional red dot)

struct HeaderIconButton: View {
    let systemName: String
    var badge: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.evOnSurface)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                if badge {
                    Circle()
                        .fill(Color.evError)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.evSurface, lineWidth: 2))
                        .offset(x: -8, y: 8)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 0) {
        GlassmorphicHeader(title: "Child Insights", kicker: "Past 7 days") {
            HStack(spacing: 4) {
                HeaderIconButton(systemName: "bell", badge: true) {}
                HeaderIconButton(systemName: "gearshape") {}
            }
        }
        Spacer()
    }
    .background(Color.evSurface)
}
