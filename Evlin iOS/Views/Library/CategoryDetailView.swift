import SwiftUI

struct CategoryDetailView: View {
    let category: CategoryTileInfo
    var onBack: () -> Void = {}

    private var detail: (heroTitle: String, heroAuthor: String, items: [LibraryMockData.DetailItem]) {
        LibraryMockData.detail(for: category.id)
    }
    private let featuredDuration: String = "12:30"

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: category.label, kicker: category.count, onBack: onBack) {
                HeaderIconButton(systemName: "bookmark") {}
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    featuredSection
                    allContentSection
                }
                .padding(16)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurfaceContainerLow)
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FEATURED")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .padding(.leading, 2)

            ZStack(alignment: .bottomLeading) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(category.gradient)
                        .frame(height: 180)

                    Circle().fill(Color.white.opacity(0.04))
                        .frame(width: 130, height: 130)
                        .offset(x: 100, y: -60)
                    Circle().fill(Color.white.opacity(0.03))
                        .frame(width: 160, height: 160)
                        .offset(x: -100, y: 70)

                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Circle().stroke(.white.opacity(0.22), lineWidth: 2)
                        )
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }

                Text(featuredDuration)
                    .font(.custom("Inter", size: 11).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .overlay(
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.heroTitle)
                        .font(.custom("Manrope", size: 16).weight(.heavy))
                        .foregroundStyle(.white)
                        .lineSpacing(-1)
                        .lineLimit(2)
                    Text(detail.heroAuthor)
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25)),
                alignment: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .evShadow(.premium)
        }
    }

    private var allContentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ALL CONTENT")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .padding(.leading, 2)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(detail.items) { item in
                    if item.kind == .video {
                        gridVideoCard(item)
                    } else {
                        gridArticleCard(item)
                    }
                }
            }
        }
    }

    private func gridVideoCard(_ item: LibraryMockData.DetailItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(category.gradient)
                Circle().fill(.white.opacity(0.18))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
            .frame(height: 110)

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

    private func gridArticleCard(_ item: LibraryMockData.DetailItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
                Image(systemName: "doc.text")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(height: 110)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1)
            )

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

#Preview {
    NavigationStack {
        CategoryDetailView(category: LibraryMockData.categories[0])
    }
}
