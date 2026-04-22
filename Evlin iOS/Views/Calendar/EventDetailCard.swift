import SwiftUI

struct EventDetailCard: View {
    let event: CalendarEvent
    let person: CalendarPerson
    let dayLabel: String
    var onClose: () -> Void = {}
    var onEdit: () -> Void = {}

    @State private var reminderOn: Bool = true

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            // Card — content-hugged height (no Spacer), natural width
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 12)

                Divider()
                personRow
                Divider()
                categoryRow
                Divider()
                noteRow
                Divider()
                locationRow
                Divider()
                reminderRow

                footer
                    .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
            )
            .shadow(color: .black.opacity(0.18), radius: 40, x: 0, y: 12)
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.evPrimary)
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(dayLabel)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.evSurfaceContainerHigh))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Rows (consistent vertical rhythm)

    private var personRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            EvlinAvatarView(url: avatarURLFor(person.id), name: person.name, size: 26, ring: true, ringColor: person.color)
            Text(person.name)
                .font(.custom("Manrope", size: 14).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var categoryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "tag")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            EvlinPill(text: event.category, tone: .neutral, size: .sm)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var noteRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
                .padding(.top, 2)
            Text(event.note)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private var locationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            Text(event.location)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var reminderRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            Text("30 minutes before")
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
            Toggle("", isOn: $reminderOn)
                .labelsHidden()
                .tint(Color.evSecondary)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center) {
            Button { onClose() } label: {
                Text("Close")
                    .font(.custom("Manrope", size: 17).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onEdit) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .bold))
                    Text("Edit")
                        .font(.custom("Manrope", size: 17).weight(.heavy))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.evPrimary)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func avatarURLFor(_ id: String) -> String? {
        switch id {
        case "liam": return ChildProfile.liam.avatarURL
        case "maya": return ChildProfile.maya.avatarURL
        case "emma": return ChildProfile.emma.avatarURL
        default:     return nil
        }
    }
}

#Preview {
    let sample = CalendarMockData.eventsByOffset[0]?.first ?? CalendarEvent(
        col: "liam", title: "Preview", emoji: "📌",
        start: "10:00 AM", end: "11:00 AM",
        category: "Study", location: "Study Room",
        note: "Preview note text."
    )
    return EventDetailCard(
        event: sample,
        person: CalendarMockData.person(sample.col),
        dayLabel: "Today, \(sample.start) – \(sample.end)"
    )
}
