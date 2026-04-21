import SwiftUI

struct LibraryView: View {
    @State private var scrolledReelId: UUID?
    @State private var selectedCategory: CategoryTileInfo? = nil

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Library") {
                HStack(spacing: 4) {
                    HeaderIconButton(systemName: "magnifyingglass") {}
                    HeaderIconButton(systemName: "bookmark") {}
                }
            }

            ScrollView {
                VStack(spacing: 24) {
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
                                    ReelCard(reel: reel)
                                        .id(reel.id)
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

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHead("Trending Lessons")
                        VStack(spacing: 12) {
                            ForEach(LibraryMockData.lessons) { lesson in
                                LessonCard(lesson: lesson)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        SectionHead("Topic Categories")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(LibraryMockData.categories) { cat in
                                CategoryTile(info: cat) {
                                    selectedCategory = cat
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurface)
        .fullScreenCover(item: $selectedCategory) { cat in
            CategoryDetailView(category: cat, onBack: { selectedCategory = nil })
        }
    }
}
