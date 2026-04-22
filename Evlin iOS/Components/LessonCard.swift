import SwiftUI

struct LessonItem: Identifiable, Hashable {
    let id = UUID()
    let author: String
    let role: String
    let title: String
    let excerpt: String
    let hearts: String
    let comments: Int

    static func == (lhs: LessonItem, rhs: LessonItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var initials: String {
        author.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
}

struct LessonCard: View {
    let lesson: LessonItem
    @State private var pressed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.evPrimaryContainer)
                    Text(lesson.initials)
                        .font(.custom("Manrope", size: 11).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(lesson.author)
                        .font(.custom("Inter", size: 12).weight(.bold))
                        .foregroundStyle(Color.evOnSurface)
                    Text(lesson.role)
                        .font(.custom("Inter", size: 10))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                Spacer()
            }

            Text(lesson.title)
                .font(.custom("Manrope", size: 17).weight(.heavy))
                .tracking(-0.17)
                .foregroundStyle(Color.evPrimary)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)

            Text(lesson.excerpt)
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                HStack(spacing: 5) {
                    Image(systemName: "heart")
                        .font(.system(size: 13))
                    Text(lesson.hearts)
                        .font(.custom("Inter", size: 11).weight(.semibold))
                }
                .foregroundStyle(Color.evOnSurfaceVariant)

                HStack(spacing: 5) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 13))
                    Text("\(lesson.comments)")
                        .font(.custom("Inter", size: 11).weight(.semibold))
                }
                .foregroundStyle(Color.evOnSurfaceVariant)

                Spacer()

                HStack(spacing: 4) {
                    Text("READ LESSON")
                        .font(.custom("Manrope", size: 10).weight(.heavy))
                        .tracking(1.4)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(Color.evPrimary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(pressed ? 0.08 : 0.04),
            radius: pressed ? 40 : 30,
            x: 0,
            y: pressed ? 20 : 10
        )
        .scaleEffect(pressed ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.18), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
