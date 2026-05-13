import SwiftUI

enum ParentReflectionStatusCardLayout {
    case homeCard
    case profileHeader
}

/// Reflection-state replacement for the standard child summary card.
///
/// `.homeCard` mirrors the image-1 Sam screenshot: the regular Home
/// `ProfileCard` shell with the status row, progress bar, and subtitle
/// swapped for an under-reflection treatment (warm tan badge, full
/// reflection bar, "Tap to see what reflection was assigned" hint).
///
/// `.profileHeader` mirrors the image-2 "Sam's Space" screenshot: a
/// warm-cream summary card with an under-reflection badge and a
/// full-width "View reflection" stripe CTA. The rest of the Profile
/// surface (current tasks, devices, rules) renders unchanged below.
struct ParentReflectionStatusCard: View {
    let child: ChildProfile
    let summary: ParentReflectionSummary
    let layout: ParentReflectionStatusCardLayout
    let onViewReflection: () -> Void

    var body: some View {
        switch layout {
        case .homeCard:
            HomeCardBody(child: child, summary: summary, onTap: onViewReflection)
        case .profileHeader:
            ProfileHeaderBody(child: child, summary: summary, onTap: onViewReflection)
        }
    }
}

// MARK: - Home card layout (image 1)

private struct HomeCardBody: View {
    let child: ChildProfile
    let summary: ParentReflectionSummary
    let onTap: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 16) {
                EvlinAvatarView(
                    url: child.avatarURL,
                    name: child.name,
                    size: 56,
                    status: child.status
                )

                VStack(alignment: .leading, spacing: 8) {
                    // Line 1: Name · age X — matches ProfileCard exactly.
                    HStack(spacing: 6) {
                        Text(child.name)
                            .font(.custom("Manrope", size: 17).weight(.heavy))
                            .tracking(-0.2)
                            .foregroundStyle(Color.evPrimary)
                        Text("· age \(child.age)")
                            .font(.custom("Inter", size: 13))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }

                    // Line 2: under-reflection badge + label (no minutes).
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(ReflectionPalette.badgeBg)
                            Image(systemName: "figure.mind.and.body")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(ReflectionPalette.badgeFg)
                        }
                        .frame(width: 20, height: 20)

                        Text("UNDER REFLECTION")
                            .font(.custom("Inter", size: 10).weight(.heavy))
                            .tracking(1.6)
                            .foregroundStyle(ReflectionPalette.badgeFg)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    // Line 3: full-width tan progress bar (visual signal,
                    // not a real countdown — the spec explicitly drops the
                    // 15M timer copy).
                    Capsule()
                        .fill(ReflectionPalette.barFill)
                        .frame(height: 5)
                        .background(
                            Capsule().fill(ReflectionPalette.barTrack)
                        )

                    // Line 4: subtitle hint.
                    Text("Tap to see what reflection was assigned")
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(ReflectionPalette.badgeFg)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
                    .padding(.top, 4)
            }
            .padding(18)
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
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .accessibilityLabel("\(child.name) is under reflection. Tap to see the assignment.")
    }
}

// MARK: - Profile header layout (image 2)

private struct ProfileHeaderBody: View {
    let child: ChildProfile
    let summary: ParentReflectionSummary
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                EvlinAvatarView(
                    url: child.avatarURL,
                    name: child.name,
                    size: 64,
                    status: .locked
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(child.name)
                        .font(.custom("Manrope", size: 26).weight(.heavy))
                        .tracking(-0.4)
                        .foregroundStyle(ReflectionPalette.nameFg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    underReflectionPill
                }

                Spacer(minLength: 0)
            }

            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.mind.and.body")
                        .font(.system(size: 18, weight: .heavy))
                    Text("View reflection")
                        .font(.custom("Manrope", size: 15).weight(.heavy))
                        .tracking(-0.1)
                }
                .foregroundStyle(ReflectionPalette.nameFg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ReflectionPalette.ctaFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(ReflectionPalette.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(child.name)'s reflection")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(ReflectionPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ReflectionPalette.border, lineWidth: 1)
        )
    }

    private var underReflectionPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.mind.and.body")
                .font(.system(size: 12, weight: .heavy))
            Text("UNDER REFLECTION")
                .font(.custom("Inter", size: 10.5).weight(.heavy))
                .tracking(1.5)
        }
        .foregroundStyle(ReflectionPalette.badgeFg)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(ReflectionPalette.pillBg)
        )
    }
}

// MARK: - Palette (mirrors reference HTML hex)

private enum ReflectionPalette {
    static let surface     = Color(red: 0xF4 / 255, green: 0xE8 / 255, blue: 0xD6 / 255)   // #F4E8D6
    static let border      = Color(red: 0xB7 / 255, green: 0x93 / 255, blue: 0x5E / 255)   // #B7935E
    static let badgeBg     = Color(red: 0xEA / 255, green: 0xD7 / 255, blue: 0xB4 / 255)   // #EAD7B4
    static let badgeFg     = Color(red: 0x6E / 255, green: 0x4F / 255, blue: 0x26 / 255)   // #6E4F26
    static let nameFg      = Color(red: 0x2E / 255, green: 0x1F / 255, blue: 0x08 / 255)   // #2E1F08
    static let pillBg      = Color(red: 0x4A / 255, green: 0x32 / 255, blue: 0x15 / 255).opacity(0.12)
    static let ctaFill     = Color(red: 0xEA / 255, green: 0xD7 / 255, blue: 0xB4 / 255)   // #EAD7B4
    static let barFill     = Color(red: 0xB7 / 255, green: 0x93 / 255, blue: 0x5E / 255)   // #B7935E
    static let barTrack    = Color(red: 0xF4 / 255, green: 0xE8 / 255, blue: 0xD6 / 255)   // #F4E8D6
}

// MARK: - Previews

private enum ParentReflectionStatusCardPreviewData {
    static var pendingSummary: ParentReflectionSummary {
        let store = ParentReflectionFixtureStore()
        store.simulateAssignment(childId: ChildProfile.liam.id)
        return store.summary(for: .liam)!
    }

    static var completedSummary: ParentReflectionSummary {
        let store = ParentReflectionFixtureStore()
        store.simulateCompletion(childId: ChildProfile.liam.id)
        return store.summary(for: .liam)!
    }
}

#Preview("Reflection Status - Home Card") {
    ParentReflectionStatusCard(
        child: .liam,
        summary: ParentReflectionStatusCardPreviewData.pendingSummary,
        layout: .homeCard,
        onViewReflection: {}
    )
    .padding()
    .background(Color.evSurface)
}

#Preview("Reflection Status - Profile Header") {
    ParentReflectionStatusCard(
        child: .liam,
        summary: ParentReflectionStatusCardPreviewData.completedSummary,
        layout: .profileHeader,
        onViewReflection: {}
    )
    .padding()
    .background(Color.evSurface)
}
