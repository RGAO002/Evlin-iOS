import SwiftUI

struct LibraryView: View {
    @State private var scrolledReelId: UUID?
    @State private var libraryPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $libraryPath) {
            VStack(spacing: 0) {
                GlassmorphicHeader(title: "Library") {
                    HStack(spacing: 4) {
                        HeaderIconButton(systemName: "magnifyingglass") {}
                        HeaderIconButton(systemName: "bookmark") {}
                    }
                }

                ScrollView {
                    VStack(spacing: 24) {
                        trendingReels
                        trendingLessons
                        topicCategories
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
            }
            .background(Color.evSurfaceContainerLow)
            .navigationDestination(for: CategoryTileInfo.self) { cat in
                CategoryDetailView(category: cat, onBack: {
                    if !libraryPath.isEmpty { libraryPath.removeLast() }
                })
            }
        }
    }

    private var trendingReels: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Trending Reels") {
                Text("60-SECOND INSIGHTS")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 15) {
                    ForEach(LibraryMockData.reels) { reel in
                        ReelCard(reel: reel).id(reel.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledReelId)
            .scrollClipDisabled()
            .padding(.horizontal, -20)
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .onChange(of: scrolledReelId) { _, _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
            }
        }
    }

    private var trendingLessons: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHead("Trending Lessons")
            VStack(spacing: 12) {
                ForEach(LibraryMockData.lessons) { lesson in
                    LessonCard(lesson: lesson)
                }
            }
        }
    }

    private var topicCategories: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead("Topic Categories")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(LibraryMockData.categories) { cat in
                    CategoryTile(info: cat) {
                        libraryPath.append(cat)
                    }
                }
            }
        }
    }
}

#Preview {
    LibraryView()
}
