import SwiftUI

struct EventDetailSheet: View {
    let event: CalendarEvent
    let person: CalendarPerson
    let dayLabel: String      // "Thu, Sep 12"
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(person.bg)
                    Text(event.emoji).font(.system(size: 28))
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.custom("Manrope", size: 19).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                    EvlinPill(text: event.category, tone: .neutral, size: .sm)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.evSurfaceContainerHigh))
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 16)

            row(icon: "calendar", label: "Date", value: dayLabel)
            row(icon: "clock", label: "Time", value: "\(event.start) – \(event.end)")
            row(icon: "mappin.and.ellipse", label: "Where", value: event.location)
            row(icon: "person.crop.circle", label: "Who", value: person.name)

            if !event.note.isEmpty {
                Text("NOTE")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.top, 18)
                Text(event.note)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .padding(.top, 4)
            }

            Spacer(minLength: 24)
        }
        .padding(22)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            Text(label.uppercased())
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.custom("Inter", size: 13).weight(.semibold))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
