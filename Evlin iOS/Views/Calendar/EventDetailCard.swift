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

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().padding(.vertical, 2)
                personRow
                Divider().padding(.vertical, 2)
                categoryRow
                Divider().padding(.vertical, 2)
                noteRow
                Divider().padding(.vertical, 2)
                locationRow
                Divider().padding(.vertical, 2)
                reminderRow
                Spacer(minLength: 8)
                footer
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
            )
            .shadow(color: .black.opacity(0.25), radius: 40, x: 0, y: 12)
            .padding(.horizontal, 24)
            .frame(maxWidth: 360)
        }
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.evPrimary)
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
                Text(dayLabel)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
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
    }

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
        .padding(.vertical, 4)
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
        .padding(.vertical, 4)
    }

    private var noteRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
                .padding(.top, 1)
            Text(event.note)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
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
        .padding(.vertical, 4)
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
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button("Close") { onClose() }
                .font(.custom("Manrope", size: 15).weight(.heavy))
                .foregroundStyle(Color.evPrimary)

            Spacer()

            Button(action: onEdit) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                    Text("Edit")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.evPrimary)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
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
