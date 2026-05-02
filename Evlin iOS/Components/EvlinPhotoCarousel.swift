import SwiftUI

/// Reusable inline photo carousel.
///
/// - Paged horizontal swipe between photos (TabView `.page`).
/// - Optional tap callback (use to push a fullscreen `PhotoGalleryViewer`).
/// - Optional thumbnail strip rendered below the main image.
/// - Keeps a `1 / N` counter pill in the top-trailing corner when there
///   are 2+ photos.
///
/// Sizing matches the pre-existing TaskDetailSheet gallery (4:3 aspect,
/// 18pt corner radius, 1pt outlineVariant stroke), so swapping the old
/// implementation for this component is visually identical aside from
/// the new swipe affordance.
struct EvlinPhotoCarousel: View {
    let photos: [String]
    /// Width / height ratio of the main image. Default 4:3.
    var aspectRatio: CGFloat = 4.0 / 3.0
    var cornerRadius: CGFloat = 18
    var showsThumbnailStrip: Bool = true
    /// Tapped photo index. Nil means tap is a no-op (carousel only).
    var onTapPhoto: ((Int) -> Void)? = nil

    @State private var currentIndex: Int = 0

    var body: some View {
        VStack(spacing: 10) {
            mainImage
            if showsThumbnailStrip && photos.count > 1 {
                thumbnailStrip
            }
        }
    }

    // MARK: - Main paged image

    private var mainImage: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(photos.enumerated()), id: \.offset) { idx, urlStr in
                photoPage(urlString: urlStr, index: idx)
                    .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // The native page-style TabView reserves space for index dots
        // even when hidden, which adds ~16pt of dead vertical space at
        // the bottom. Trim that off so the image fills its 4:3 frame
        // exactly.
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.evOutlineVariant, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if photos.count > 1 {
                Text("\(currentIndex + 1) / \(photos.count)")
                    .font(.custom("Inter", size: 11).weight(.heavy))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(10)
            }
        }
    }

    private func photoPage(urlString: String, index: Int) -> some View {
        AsyncImage(url: URL(string: urlString)) { phase in
            if let img = phase.image {
                img.resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.evSurfaceContainerLow)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { onTapPhoto?(index) }
    }

    // MARK: - Thumbnail strip

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.offset) { idx, urlStr in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            currentIndex = idx
                        }
                    } label: {
                        AsyncImage(url: URL(string: urlStr)) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Rectangle().fill(Color.evSurfaceContainerLow)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(idx == currentIndex ? Color.evPrimary : Color.evOutlineVariant,
                                              lineWidth: idx == currentIndex ? 2 : 1)
                        )
                        .opacity(idx == currentIndex ? 1.0 : 0.75)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#Preview("3 photos") {
    EvlinPhotoCarousel(
        photos: [
            "https://images.unsplash.com/photo-1532619675605-1ede6c2ed2b0?w=800&q=80",
            "https://images.unsplash.com/photo-1581094271901-8022df4466f9?w=800&q=80",
            "https://images.unsplash.com/photo-1606326608606-aa0b62935f2b?w=800&q=80",
        ]
    )
    .padding(20)
    .background(Color.evSurface)
}
