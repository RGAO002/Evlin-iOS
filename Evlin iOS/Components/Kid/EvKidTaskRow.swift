import SwiftUI

struct EvKidTaskRow: View {
    enum Palette { case green, brown }

    let task: BigKidTask
    let palette: Palette
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                checkCircle
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 16, weight: .bold))
                        .tracking(EvlinKidMetrics.Letter.body)
                        .foregroundStyle(titleColor)
                        .strikethrough(task.status == .done, color: titleStrikeColor)
                        .opacity(task.status == .done ? 0.55 : 1)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        categoryChip
                        if task.status == .submitted {
                            Label("evidence", systemImage: "camera.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(submittedColor)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if let due = task.due, task.status != .done {
                        Text("Due \(due)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(dueColor)
                    }
                }
                Spacer(minLength: 0)
                statusChip
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(rowBg)
            .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.row))
            .overlay(
                RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.row)
                    .stroke(rowBorderColor, lineWidth: rowBorderWidth)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var checkCircle: some View {
        if task.status == .done {
            ZStack {
                Circle().fill(palette == .green ? EvlinKidColors.green500 : EvlinKidColors.Reflection.checkBg)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: EvlinKidMetrics.Size.taskCheckCircle,
                   height: EvlinKidMetrics.Size.taskCheckCircle)
        } else {
            Circle()
                .stroke(checkStrokeColor, lineWidth: 2)
                .background(Circle().fill(.white))
                .frame(width: EvlinKidMetrics.Size.taskCheckCircle,
                       height: EvlinKidMetrics.Size.taskCheckCircle)
        }
    }

    @ViewBuilder
    private var categoryChip: some View {
        let (bg, fg) = categoryColors
        let emoji = categoryEmoji
        Text("\(emoji) \(task.category.rawValue)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
    }

    @ViewBuilder
    private var statusChip: some View {
        switch task.status {
        case .done:
            chip(text: "Done", bg: doneChipBg, fg: doneChipFg)
        case .submitted:
            chip(text: "Submitted", bg: submittedChipBg, fg: submittedChipFg)
        case .overdue:
            chip(text: "!", bg: overdueChipBg, fg: overdueChipFg)
        case .todo:
            chip(text: "To do", bg: todoChipBg, fg: todoChipFg)
        }
    }

    private func chip(text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.1)
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bg, in: Capsule())
    }

    // MARK: - Per-palette colors (mirrors home.jsx vs home-reflection.jsx)

    private var titleColor: Color {
        palette == .green ? EvlinKidColors.ink : Color(red: 46/255, green: 31/255, blue: 8/255)
    }
    private var titleStrikeColor: Color {
        palette == .green ? EvlinKidColors.ink4 : Color(red: 183/255, green: 147/255, blue: 94/255)
    }
    private var submittedColor: Color {
        palette == .green ? EvlinKidColors.green600 : Color(red: 110/255, green: 79/255, blue: 38/255)
    }
    private var dueColor: Color {
        // home.jsx line 138: overdue = '#C8324A', else ink3
        if task.status == .overdue { return Color(red: 200/255, green: 50/255, blue: 74/255) }
        return palette == .green ? EvlinKidColors.ink3 : Color(red: 110/255, green: 79/255, blue: 38/255)
    }
    private var checkStrokeColor: Color {
        if task.status == .overdue {
            return palette == .green ? EvlinKidColors.green500 : Color(red: 110/255, green: 79/255, blue: 38/255)
        }
        return palette == .green ? EvlinKidColors.ink4 : EvlinKidColors.Reflection.cardBorder
    }
    private var rowBg: Color {
        if task.status == .done {
            return palette == .green ? EvlinKidColors.surface2 : EvlinKidColors.Reflection.rowBgDone
        }
        if task.status == .submitted {
            return palette == .green ? EvlinKidColors.green50 : EvlinKidColors.Reflection.rowBgSubmitted
        }
        return .white
    }
    private var rowBorderColor: Color {
        if task.status == .submitted {
            return palette == .green ? EvlinKidColors.green200 : EvlinKidColors.Reflection.cardBorder
        }
        if task.status == .overdue {
            return palette == .green ? EvlinKidColors.green400 : Color(red: 154/255, green: 115/255, blue: 64/255)
        }
        return palette == .green ? EvlinKidColors.line : EvlinKidColors.Reflection.rowBorder
    }
    private var rowBorderWidth: CGFloat {
        task.status == .overdue ? 1.5 : 1
    }
    private var categoryColors: (bg: Color, fg: Color) {
        // home.jsx CAT_STYLE lines 7–11
        switch (task.category, palette) {
        case (.chores, .green):    return (EvlinKidColors.green100, EvlinKidColors.green700)
        case (.homework, .green):  return (Color(red: 228/255, green: 236/255, blue: 251/255),
                                          Color(red:  46/255, green:  78/255, blue: 147/255))
        case (.selfCare, .green):  return (Color(red: 253/255, green: 231/255, blue: 238/255),
                                          Color(red: 177/255, green:  58/255, blue: 100/255))
        case (_, .brown):          return (EvlinKidColors.Reflection.chipBg, EvlinKidColors.Reflection.chipFg)
        }
    }
    private var categoryEmoji: String {
        switch task.category { case .chores: "🧹"; case .homework: "📚"; case .selfCare: "💗" }
    }
    private var doneChipBg: Color { palette == .green ? EvlinKidColors.green100 : EvlinKidColors.Reflection.chipBg }
    private var doneChipFg: Color { palette == .green ? EvlinKidColors.green700 : EvlinKidColors.Reflection.chipFg }
    private var submittedChipBg: Color { palette == .green ? EvlinKidColors.green50 : Color(red: 244/255, green: 232/255, blue: 214/255) }
    private var submittedChipFg: Color { palette == .green ? EvlinKidColors.green600 : Color(red: 110/255, green: 79/255, blue: 38/255) }
    private var overdueChipBg: Color { palette == .green ? EvlinKidColors.green200 : Color(red: 212/255, green: 181/255, blue: 132/255) }
    private var overdueChipFg: Color { palette == .green ? EvlinKidColors.green800 : Color(red: 46/255, green: 31/255, blue: 8/255) }
    private var todoChipBg: Color { palette == .green ? EvlinKidColors.surface2 : Color(red: 244/255, green: 232/255, blue: 214/255) }
    private var todoChipFg: Color { palette == .green ? EvlinKidColors.ink3 : Color(red: 110/255, green: 79/255, blue: 38/255) }
}

#if DEBUG
#Preview("Green") {
    VStack(spacing: 10) {
        EvKidTaskRow(task: .fixture(status: .todo), palette: .green) {}
        EvKidTaskRow(task: .fixture(status: .submitted), palette: .green) {}
        EvKidTaskRow(task: .fixture(status: .done), palette: .green) {}
        EvKidTaskRow(task: .fixture(status: .overdue), palette: .green) {}
    }
    .padding()
}
#Preview("Brown") {
    VStack(spacing: 10) {
        EvKidTaskRow(task: .fixture(status: .todo), palette: .brown) {}
        EvKidTaskRow(task: .fixture(status: .submitted), palette: .brown) {}
        EvKidTaskRow(task: .fixture(status: .done), palette: .brown) {}
    }
    .padding()
    .background(EvlinKidColors.Reflection.bgSurface)
}
#endif
