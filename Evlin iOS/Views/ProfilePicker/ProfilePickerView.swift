import SwiftUI

// MARK: - DEPRECATED / RETAINED FOR REFERENCE
// Replaced by HomeView's dashboard (see Views/Home/HomeView.swift), which
// handles child profile selection as part of the main parent flow.
// Not wired into ContentView routing. Kept on disk per spec §2 preservation
// rule. Do not delete. Do not wire back in without updating spec.

// MARK: - Netflix-style Profile Picker
// App entry point — parent selects which child they're managing.
// Mock data for now (Liam / Emma / Sophia + Add child).

struct ProfilePickerView: View {
    let onSelect: (ChildProfile) -> Void
    var onAddChild: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil

    @State private var appearScale: CGFloat = 0.85
    @State private var appearOpacity: Double = 0

    private let profiles = ChildProfile.all

    var body: some View {
        ZStack {
            // Deep navy gradient background
            LinearGradient(
                colors: [
                    Color(hex: 0x041627),
                    Color(hex: 0x0B1F33),
                    Color(hex: 0x1A2B3C)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: Spacing.section) {
                Spacer(minLength: Spacing.page)

                header

                Spacer(minLength: Spacing.xxxl)

                profileGrid
                    .scaleEffect(appearScale)
                    .opacity(appearOpacity)

                Spacer()

                footerHint
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)

            // Settings gear, top-right
            if onSettings != nil {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            onSettings?()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.6))
                                .padding(Spacing.lg)
                                .background(
                                    Circle()
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.md)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.1)) {
                appearScale = 1.0
                appearOpacity = 1.0
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: Spacing.lg) {
            Text("EVLIN")
                .font(.custom("Manrope", size: 14).weight(.heavy))
                .tracking(6)
                .foregroundStyle(Color.evSecondaryFixed.opacity(0.85))

            Text("Who's using Evlin?")
                .font(.custom("Manrope", size: 32).weight(.heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("Select a profile to continue")
                .font(.evBodyMedium)
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private var profileGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: Spacing.xl),
            GridItem(.flexible(), spacing: Spacing.xl),
            GridItem(.flexible(), spacing: Spacing.xl)
        ]

        return LazyVGrid(columns: columns, spacing: Spacing.xxxl) {
            ForEach(profiles) { profile in
                ProfileTile(profile: profile) {
                    onSelect(profile)
                }
            }

            if onAddChild != nil {
                AddProfileTile {
                    onAddChild?()
                }
            }
        }
    }

    private var footerHint: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 11, weight: .semibold))
            Text("The Informed Sentinel")
                .font(.evLabelSmall)
                .evLabelStyle()
        }
        .foregroundStyle(Color.white.opacity(0.35))
    }
}

// MARK: - Profile Tile

private struct ProfileTile: View {
    let profile: ChildProfile
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                isPressed = false
                action()
            }
        } label: {
            VStack(spacing: Spacing.lg) {
                ZStack {
                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    profile.accentColor,
                                    profile.accentColor.opacity(0.7)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                                .stroke(Color.white.opacity(isPressed ? 0.9 : 0.15), lineWidth: isPressed ? 2 : 1)
                        )
                        .shadow(color: profile.accentColor.opacity(0.35), radius: 14, x: 0, y: 8)

                    Text(profile.initial)
                        .font(.system(size: 44))
                }
                .frame(height: 96)
                .scaleEffect(isPressed ? 1.05 : 1.0)

                VStack(spacing: 2) {
                    Text(profile.name)
                        .font(.custom("Manrope", size: 15).weight(.bold))
                        .foregroundStyle(.white)

                    Text("Age \(profile.age)")
                        .font(.evLabelSmall)
                        .evLabelStyle()
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add Profile Tile

private struct AddProfileTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.lg) {
                RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.2),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .frame(height: 96)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                    )

                VStack(spacing: 2) {
                    Text("Add child")
                        .font(.custom("Manrope", size: 15).weight(.bold))
                        .foregroundStyle(Color.white.opacity(0.6))

                    Text(" ")
                        .font(.evLabelSmall)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ProfilePickerView(
        onSelect: { _ in },
        onAddChild: { },
        onSettings: { }
    )
}
