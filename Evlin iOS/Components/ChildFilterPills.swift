import SwiftUI

struct ChildFilterPills: View {
    @Binding var selection: String   // "all" | "liam" | "maya" | "emma"
    var includeAll: Bool = true

    private var items: [(id: String, label: String, color: Color)] {
        var arr: [(String, String, Color)] = []
        if includeAll {
            arr.append(("all", "All", .evPrimary))
        }
        for c in ChildProfile.all { arr.append((c.id, c.name, c.accentColor)) }
        return arr
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.id) { item in
                    pill(id: item.id, label: item.label, color: item.color)
                }
            }
        }
    }

    @ViewBuilder
    private func pill(id: String, label: String, color: Color) -> some View {
        let on = selection == id
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = id }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                    .font(.custom("Manrope", size: 12).weight(.bold))
            }
            .foregroundStyle(on ? Color.white : Color.evPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(on ? Color.evPrimary : Color.evSurfaceContainerLowest)
            )
            .overlay(
                Capsule().stroke(on ? Color.clear : Color.evOutlineVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
