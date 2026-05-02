import SwiftUI

/// Mirrors `primitives.jsx :: EvBackButton`. Chevron + label, primary green tint.
struct EvKidBackButton: View {
    let label: String?
    let action: () -> Void

    init(label: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                if let label {
                    Text(label)
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .foregroundStyle(EvlinKidColors.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .offset(x: -4)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    EvKidBackButton(label: "Today", action: {})
        .padding()
}
