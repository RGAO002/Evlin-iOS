import SwiftUI

struct NotificationPanel: View {
    var onClose: () -> Void
    @State private var notifs: [HomeNotification] = HomeMockData.notifications

    private var unread: Int { notifs.filter(\.unread).count }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(
                title: "Notifications",
                kicker: unread > 0 ? "\(unread) unread" : nil,
                onBack: onClose
            ) {
                if unread > 0 {
                    Button {
                        withAnimation { notifs = notifs.map { var n = $0; n.unread = false; return n } }
                    } label: {
                        Text("Mark all read")
                            .font(.custom("Inter", size: 12).weight(.bold))
                            .foregroundStyle(Color.evPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if notifs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 40))
                    Text("All caught up")
                        .font(.custom("Inter", size: 14))
                }
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notifs) { n in
                            row(for: n)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation { notifs.removeAll { $0.id == n.id } }
                                    } label: {
                                        Label("Dismiss", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color.evSurfaceContainerLow)
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder
    private func row(for n: HomeNotification) -> some View {
        let color = HomeMockData.childColor(n.childId)
        Button {
            withAnimation {
                if let idx = notifs.firstIndex(where: { $0.id == n.id }) {
                    notifs[idx].unread = false
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if n.unread {
                    Circle().fill(color).frame(width: 6, height: 6).offset(y: 8)
                } else {
                    Color.clear.frame(width: 6, height: 6).offset(y: 8)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(color.opacity(0.12))
                    if let url = HomeMockData.avatarURL(n.childId), let u = URL(string: url) {
                        AsyncImage(url: u) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Image(systemName: n.iconSystemName)
                                    .font(.system(size: 16))
                                    .foregroundStyle(color)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    } else {
                        Image(systemName: n.iconSystemName)
                            .font(.system(size: 18))
                            .foregroundStyle(color)
                    }
                }
                .frame(width: 42, height: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(color.opacity(0.25), lineWidth: 1.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(n.title)
                            .font(.custom("Manrope", size: 13).weight(.heavy))
                            .foregroundStyle(Color.evPrimary)
                        Spacer()
                        Text(n.time)
                            .font(.custom("Inter", size: 10))
                            .foregroundStyle(Color.evOutline)
                    }
                    Text(n.body)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineSpacing(1)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .background(n.unread ? color.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
            alignment: .bottom
        )
    }
}
