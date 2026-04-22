import SwiftUI

struct MonthPickerSheet: View {
    @Binding var selectedDate: Date
    var onClose: () -> Void

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(CalendarMockData.monthName(selectedDate))
                .font(.custom("Manrope", size: 22).weight(.heavy))
                .foregroundStyle(Color.evPrimary)

            HStack(spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { d in
                    Text(d)
                        .font(.custom("Inter", size: 11).weight(.bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(cells.indices, id: \.self) { idx in
                    if let d = cells[idx] {
                        dayCell(d)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.light)
    }

    private var weekdaySymbols: [String] {
        let f = DateFormatter()
        f.locale = .current
        return f.veryShortStandaloneWeekdaySymbols
    }

    private var cells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: selectedDate),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate))
        else { return [] }
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingBlanks = firstWeekday - 1
        var result: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                result.append(d)
            }
        }
        return result
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let day = calendar.component(.day, from: date)
        Button {
            selectedDate = date
            onClose()
        } label: {
            ZStack {
                Circle().fill(isSelected ? Color.evPrimary : Color.clear)
                if isToday && !isSelected {
                    Circle().stroke(Color.evPrimary, lineWidth: 1.5)
                }
                Text("\(day)")
                    .font(.custom("Manrope", size: 15).weight(.heavy))
                    .foregroundStyle(isSelected ? Color.white : Color.evOnSurface)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
        }
        .buttonStyle(.plain)
    }
}
