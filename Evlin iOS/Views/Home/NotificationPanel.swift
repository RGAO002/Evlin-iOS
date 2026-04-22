import SwiftUI

struct NotificationPanel: View {
    var onClose: () -> Void
    @State private var notifs: [HomeNotification] = HomeMockData.notifications

    private var unread: Int { notifs.filter(\.unread).count }

    var body: some View {
        VStack(spacing: 0) {
            customHeader
            content
        }
        .background(Color.evSurfaceContainerLow)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
    }

    // MARK: - Custom header (per screenshot)

    private var customHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onClose) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.evSurfaceContainerHigh)
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications")
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
                if unread > 0 {
                    Text("\(unread) unread")
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }
            .padding(.top, 4)

            Spacer()

            if unread > 0 {
                Button {
                    withAnimation { notifs = notifs.map { var n = $0; n.unread = false; return n } }
                } label: {
                    Text("Mark all read")
                        .font(.custom("Inter", size: 13).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(
            Color.evSurfaceContainerLow
                .ignoresSafeArea(edges: .top)
        )
    }

    @ViewBuilder
    private var content: some View {
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
                    }
                }
                .padding(.vertical, 8)
            }
        }
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
                    Circle().fill(color).frame(width: 6, height: 6).offset(y: 10)
                } else {
                    Color.clear.frame(width: 6, height: 6).offset(y: 10)
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
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(color.opacity(0.25), lineWidth: 1.5)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(n.title)
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                    Text(n.body)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 10) {
                    Text(n.time)
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOutline)
                    Button {
                        withAnimation { notifs.removeAll { $0.id == n.id } }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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

