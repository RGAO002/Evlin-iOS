import SwiftUI

struct LessonItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let durationMin: Int
    let gradient: LinearGradient

    static func == (lhs: LessonItem, rhs: LessonItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct LessonCard: View {
    let lesson: LessonItem

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(lesson.gradient)
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(lesson.title)
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)
                    .lineLimit(2)
                Text(lesson.subtitle)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(1)
                Text("\(lesson.durationMin) min")
                    .font(.custom("Inter", size: 10).weight(.bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.evOutline)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
        .evShadow(.premium)
    }
}
