import SwiftUI

// MARK: - Circular avatar with optional status lock dot
// Mirrors Esen's Avatar from ui.jsx lines 235-274.

struct EvlinAvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 48
    var status: ChildProfile.Status? = nil
    var ring: Bool = false
    var ringColor: Color = .evPrimary
    @State private var retryID: Int = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url, let u = URL(string: url) {
                    avatarImage(url: u)
                } else {
                    fallback
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle().stroke(ring ? ringColor : Color.white, lineWidth: ring ? 3 : 2)
            )
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)

            if let status {
                statusDot(status: status)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: url) { _, _ in retryID = 0 }
    }

    @ViewBuilder
    private func avatarImage(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
            case .failure:
                fallback
                    .task(id: retryID) {
                        guard retryID < 2 else { return }
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        if !Task.isCancelled {
                            retryID += 1
                        }
                    }
            default:
                fallback
            }
        }
        .id("\(url.absoluteString)#\(retryID)")
    }

    private var fallback: some View {
        ZStack {
            Color.evPrimaryContainer
            Text(String(name.prefix(1)).uppercased())
                .font(.custom("Manrope", size: size * 0.38).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
        }
    }

    private func statusDot(status: ChildProfile.Status) -> some View {
        ZStack {
            Circle()
                .fill(status == .unlocked ? AnyShapeStyle(Color.evSecondaryGradient) : AnyShapeStyle(Color.evSurfaceContainerHighest))
                .frame(width: size * 0.32, height: size * 0.32)
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
            Image(systemName: status == .unlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: size * 0.17, weight: .bold))
                .foregroundStyle(status == .unlocked ? Color.white : Color.evOnSurfaceVariant)
        }
        .offset(x: 2, y: 2)
    }
}
