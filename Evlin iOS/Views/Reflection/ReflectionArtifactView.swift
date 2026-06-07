import SwiftUI

/// Standalone "Reflection Assignment" page — used by the notification
/// deep-link (`AppRoute.reflectionArtifact(reflectionId:)`).
///
/// On the Profile screen, the same content renders INLINE via
/// `ReflectionAssignmentListing`, replacing the Current Tasks /
/// Devices / Rules sections while the user is in the reflection
/// sub-tab. This standalone wrapper exists for entry points that
/// don't pass through Profile (notifications + future deep links).
struct ReflectionArtifactView: View {
    let reflectionId: UUID
    var onBack: (() -> Void)? = nil

    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @State private var activeAlert: ReflectionArtifactAlert?

    private var summary: ParentReflectionSummary? {
        reflectionStore.summary(reflectionId: reflectionId)
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Reflection", kicker: "Parent review", onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let summary {
                        ReflectionAssignmentListing(
                            summary: summary,
                            onCancel: {
                                activeAlert = .cancelConfirmed(summary.childName)
                            }
                        )
                    } else {
                        missingState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 60)
            }
        }
        .background(Color.evSurfaceContainerLow.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var missingState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(MissingStatePalette.brown)
                .frame(width: 58, height: 58)
                .background(Circle().fill(MissingStatePalette.badgeBg))

            Text("Reflection unavailable")
                .font(.custom("Manrope", size: 22).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(MissingStatePalette.ink)

            Text("This reflection could not be found. It may have been cancelled or expired.")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(MissingStatePalette.brown)
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
    }
}

private enum MissingStatePalette {
    static let surface = Color(red: 0xF4 / 255, green: 0xE8 / 255, blue: 0xD6 / 255)
    static let border  = Color(red: 0xB7 / 255, green: 0x93 / 255, blue: 0x5E / 255)
    static let badgeBg = Color(red: 0xEA / 255, green: 0xD7 / 255, blue: 0xB4 / 255)
    static let brown   = Color(red: 0x6E / 255, green: 0x4F / 255, blue: 0x26 / 255)
    static let ink     = Color(red: 0x2E / 255, green: 0x1F / 255, blue: 0x08 / 255)
}

private enum ReflectionArtifactAlert: Identifiable {
    case cancelConfirmed(String)

    var id: String {
        switch self {
        case .cancelConfirmed:
            return "cancelConfirmed"
        }
    }

    var title: String {
        switch self {
        case .cancelConfirmed:
            return "Cancel reflection"
        }
    }

    var message: String {
        switch self {
        case .cancelConfirmed(let childName):
            return "Prototype only: \(childName)'s reflection would be cancelled."
        }
    }
}

private enum ReflectionArtifactPreviewData {
    static var completedStore: ParentReflectionFixtureStore {
        let store = ParentReflectionFixtureStore()
        store.simulateCompletion(childId: ChildProfile.previewLiam.id)
        return store
    }

    static var pendingStore: ParentReflectionFixtureStore {
        let store = ParentReflectionFixtureStore()
        store.simulateAssignment(childId: ChildProfile.previewLiam.id)
        return store
    }

    static var completedSummaryId: UUID? {
        completedStore.summary(for: .previewLiam)?.id
    }

    static var pendingSummaryId: UUID? {
        pendingStore.summary(for: .previewLiam)?.id
    }
}

#Preview("Reflection Artifact — Finished") {
    if let id = ReflectionArtifactPreviewData.completedSummaryId {
        NavigationStack {
            ReflectionArtifactView(reflectionId: id, onBack: {})
        }
        .environment(ReflectionArtifactPreviewData.completedStore)
    } else {
        Text("Missing fixture")
    }
}

#Preview("Reflection Artifact — Pending") {
    if let id = ReflectionArtifactPreviewData.pendingSummaryId {
        NavigationStack {
            ReflectionArtifactView(reflectionId: id, onBack: {})
        }
        .environment(ReflectionArtifactPreviewData.pendingStore)
    } else {
        Text("Missing fixture")
    }
}
