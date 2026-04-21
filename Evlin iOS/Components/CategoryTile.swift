import SwiftUI

struct CategoryTileInfo: Identifiable, Hashable {
    let id: String      // "ei", "digital", "conflict", "growth"
    let label: String
    let count: String   // "12 series"
    let iconSystemName: String
    let gradient: LinearGradient

    static func == (lhs: CategoryTileInfo, rhs: CategoryTileInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct CategoryTile: View {
    let info: CategoryTileInfo
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: info.iconSystemName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(info.count.uppercased())
                    .font(.custom("Inter", size: 9).weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
                Text(info.label)
                    .font(.custom("Manrope", size: 16).weight(.heavy))
                    .lineSpacing(-1)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(info.gradient))
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}
