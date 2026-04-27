import SwiftUI

struct ReelItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let author: String
    let gradient: LinearGradient

    static func == (lhs: ReelItem, rhs: ReelItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ReelCard: View {
    let reel: ReelItem
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(reel.gradient)

                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reel.author.uppercased())
                            .font(.custom("Inter", size: 9).weight(.heavy))
                            .tracking(1.0)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(reel.title)
                            .font(.custom("Manrope", size: 13).weight(.heavy))
                            .lineSpacing(0)
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
            .frame(width: 148, height: 214)
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}
