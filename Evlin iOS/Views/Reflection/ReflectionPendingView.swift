import SwiftUI

/// Pending and finished reflections render the same shell — see
/// `ReflectionArtifactView`. This thin wrapper exists only so the
/// `AppRoute.reflectionPending(childId:)` case can resolve the child's
/// current summary to a reflection id and forward.
///
/// Per spec/design conversation: pending state should NOT show a fake
/// step-progress hero, a separate "Prototype actions" section, or an
/// "Assignment summary" detail table. The same Reflection Assignment
/// listing renders in both states; only the state pill on top and
/// Step 3's right-side review pill change.
struct ReflectionPendingView: View {
    let childId: String
    var onBack: (() -> Void)? = nil

    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore

    private var summary: ParentReflectionSummary? {
        reflectionStore.summary(childId: childId)
    }

    var body: some View {
        if let summary {
            ReflectionArtifactView(reflectionId: summary.id, onBack: onBack)
        } else {
            VStack(spacing: 0) {
                GlassmorphicHeader(title: "Reflection", kicker: "Parent status", onBack: onBack)

                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(MissingStatePalette.badgeFg)
                        .frame(width: 58, height: 58)
                        .background(
                            Circle().fill(MissingStatePalette.badgeBg)
                        )

                    Text("No reflection assigned")
                        .font(.custom("Manrope", size: 22).weight(.heavy))
                        .tracking(-0.3)
                        .foregroundStyle(MissingStatePalette.nameFg)

                    Text("There isn't an active reflection for this child right now.")
                        .font(.custom("Inter", size: 13))
                        .foregroundStyle(MissingStatePalette.badgeFg)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(MissingStatePalette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(MissingStatePalette.border, lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .padding(.top, 18)

                Spacer()
            }
            .background(Color.evSurfaceContainerLow.ignoresSafeArea())
            .navigationBarBackButtonHidden(true)
            .enableSwipeBack()
        }
    }
}

private enum MissingStatePalette {
    static let surface = Color(red: 0xF4 / 255, green: 0xE8 / 255, blue: 0xD6 / 255)
    static let border  = Color(red: 0xB7 / 255, green: 0x93 / 255, blue: 0x5E / 255)
    static let badgeBg = Color(red: 0xEA / 255, green: 0xD7 / 255, blue: 0xB4 / 255)
    static let badgeFg = Color(red: 0x6E / 255, green: 0x4F / 255, blue: 0x26 / 255)
    static let nameFg  = Color(red: 0x2E / 255, green: 0x1F / 255, blue: 0x08 / 255)
}

#Preview("Reflection Pending — wraps Artifact") {
    let store = ParentReflectionFixtureStore()
    store.simulateAssignment(childId: ChildProfile.previewLiam.id)
    return NavigationStack {
        ReflectionPendingView(childId: ChildProfile.previewLiam.id, onBack: {})
    }
    .environment(store)
}

#Preview("Reflection Pending — empty") {
    NavigationStack {
        ReflectionPendingView(childId: ChildProfile.previewMaya.id, onBack: {})
    }
    .environment(ParentReflectionFixtureStore())
}
