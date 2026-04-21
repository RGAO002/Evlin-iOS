import SwiftUI

struct CategoryDetailView: View {
    let category: CategoryTileInfo
    var onBack: () -> Void = {}

    private var detail: (heroTitle: String, heroAuthor: String, items: [LibraryMockData.DetailItem]) {
        LibraryMockData.detail(for: category.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: category.label, onBack: onBack) {
                HeaderIconButton(systemName: "bookmark") {}
            }

            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(category.gradient)
                            .frame(height: 200)
                            .overlay(alignment: .bottomLeading) {
                                VStack(alignment: .leading, spacing: 6) {
                                    EvlinPill(text: "Featured", tone: .primary, size: .xs)
                                    Text(detail.heroTitle)
                                        .font(.custom("Manrope", size: 20).weight(.heavy))
                                        .foregroundStyle(.white)
                                    Text(detail.heroAuthor.uppercased())
                                        .font(.custom("Inter", size: 10).weight(.heavy))
                                        .tracking(1.2)
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                                .padding(18)
                            }
                            .overlay(alignment: .topTrailing) {
                                Circle().fill(.white.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(.white)
                                    )
                                    .padding(18)
                            }
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(detail.items) { item in
                            itemCard(item)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurface)
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder
    private func itemCard(_ item: LibraryMockData.DetailItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(category.gradient)
                    .opacity(item.kind == .video ? 1.0 : 0.2)
                Image(systemName: item.kind == .video ? "play.circle.fill" : "doc.text")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(item.kind == .video ? .white : Color.evPrimary)
            }
            .frame(height: 100)

            Text(item.title)
                .font(.custom("Manrope", size: 13).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(item.meta.uppercased())
                .font(.custom("Inter", size: 9).weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
    }
}
