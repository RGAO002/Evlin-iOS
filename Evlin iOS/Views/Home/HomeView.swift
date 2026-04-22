import SwiftUI

struct HomeView: View {
    @AppStorage("parentName") private var parentName: String = "Morgan"
    @State private var showSettings = false
    @Binding var selectedTab: EvlinTab
    var onOpenProfile: (ChildProfile) -> Void
    var onOpenNotifications: () -> Void

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning" }
        if h < 18 { return "Good afternoon" }
        return "Good evening"
    }

    private var unreadCount: Int {
        HomeMockData.notifications.filter(\.unread).count
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "", kicker: "\(greeting), \(parentName)") {
                HStack(spacing: 4) {
                    HeaderIconButton(systemName: "bell", badge: unreadCount > 0) {
                        onOpenNotifications()
                    }
                    HeaderIconButton(systemName: "gearshape") {
                        showSettings = true
                    }
                }
            }

            ScrollView {
                VStack(spacing: 28) {
                    // Children section
                    VStack(spacing: 14) {
                        SectionHead("Children", kicker: "Select a profile")
                        ForEach(ChildProfile.all) { child in
                            ProfileCard(child: child) {
                                onOpenProfile(child)
                            }
                        }
                    }

                    // Evlin observation prompt
                    Button {
                        selectedTab = .chat
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.evPrimaryGradient)
                                    .frame(width: 44, height: 44)
                                Image(systemName: "sparkles")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Evlin has 3 observations for you")
                                    .font(.custom("Manrope", size: 14).weight(.heavy))
                                    .foregroundStyle(Color.evPrimary)
                                Text("Incl. one late-night gaming pattern · Liam")
                                    .font(.custom("Inter", size: 12))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.evOutline)
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.evSurfaceContainerLow)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.evOutlineVariant, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurfaceContainerLow)
        .fullScreenCover(isPresented: $showSettings) {
            HomeSettingsSheet(onClose: { showSettings = false })
        }
    }
}
