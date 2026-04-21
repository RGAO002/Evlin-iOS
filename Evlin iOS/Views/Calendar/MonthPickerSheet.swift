import SwiftUI

struct MonthPickerSheet: View {
    @Binding var selectedDay: Int
    var onClose: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("September")
                .font(.custom("Manrope", size: 22).weight(.heavy))
                .foregroundStyle(Color.evPrimary)

            HStack(spacing: 6) {
                ForEach(["S","M","T","W","T","F","S"], id: \.self) { d in
                    Text(d).font(.custom("Inter", size: 11).weight(.bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(1...30, id: \.self) { d in
                    let on = d == selectedDay
                    Button {
                        selectedDay = d
                        onClose()
                    } label: {
                        Text("\(d)")
                            .font(.custom("Manrope", size: 15).weight(.heavy))
                            .foregroundStyle(on ? Color.white : Color.evOnSurface)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                Circle().fill(on ? Color.evPrimary : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
