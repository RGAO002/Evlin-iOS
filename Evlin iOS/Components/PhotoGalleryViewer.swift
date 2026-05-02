import SwiftUI

/// Full-screen photo browser modelled on Apple Photos. Pinch to zoom,
/// double-tap to toggle 1× / 2×, drag to pan / page-change / dismiss
/// depending on context.
///
/// Architecture (and the one important departure from
/// `~/Desktop/Lync/Lync/Components/FullscreenImageViewer`): we replace
/// the previous `TabView(.page)` with a hand-rolled horizontal pager.
/// TabView attaches its own internal gesture for page-flicking, which
/// fires *in parallel* with our pan-when-zoomed gesture — that is what
/// caused the original "drag to pan and switch photo at the same time"
/// overlap. With a single drag gesture driving everything, we decide on
/// drag-start whether the user is panning, paging, or dismissing, and
/// honour that mode for the rest of the drag.
///
/// Drag modes:
/// - `.dismissing` (1× only, vertical-dominant motion): translates the
///   whole gallery vertically and fades the backdrop.
/// - `.paging` (1× only, horizontal-dominant motion): translates the
///   pager strip; release commits or snaps back.
/// - `.panning` (zoomed, any direction): pans within the current image.
///   When the proposed pan position would cross the image's pan
///   boundary, the excess motion is forwarded to the pager strip — this
///   is the "drag past the edge to switch photo" behaviour Apple Photos
///   uses, so panning and paging never overlap on the same finger.
struct PhotoGalleryViewer: View {
    let photos: [String]
    var startIndex: Int = 0
    @Binding var isPresented: Bool

    @State private var currentIndex: Int = 0
    @State private var backgroundOpacity: Double = 1.0

    // Per-photo zoom + pan. Reset on page change (so each photo starts
    // at 1×, centred). We deliberately don't carry zoom state across
    // pages — that's the standard photo browser behaviour and avoids
    // surprising "previous photo is still zoomed" reveals while paging.
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    // Live horizontal offset added on top of the discrete `currentIndex`
    // page position. Non-zero only mid-drag (paging or pan-overflow).
    @State private var pagerDragX: CGFloat = 0

    // Live vertical offset for drag-to-dismiss. Applied to the whole
    // gallery (not just the current photo) so the controls overlay
    // travels down with the finger as well.
    @State private var dismissOffsetY: CGFloat = 0

    @State private var dragMode: DragMode = .undecided

    private enum DragMode {
        case undecided
        case panning
        case paging
        case dismissing
    }

    private var isZoomed: Bool { scale > 1.05 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(backgroundOpacity)
                    .ignoresSafeArea()

                pager(viewSize: geo.size)

                controlsOverlay
            }
            .offset(y: dismissOffsetY)
            .contentShape(Rectangle())
            .gesture(magnification)
            .simultaneousGesture(dragGesture(viewSize: geo.size))
            .onTapGesture(count: 2) { handleDoubleTap() }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear {
            currentIndex = max(0, min(startIndex, photos.count - 1))
        }
    }

    // MARK: - Pager

    private func pager(viewSize: CGSize) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(photos.enumerated()), id: \.offset) { idx, urlStr in
                photoContent(urlString: urlStr)
                    .frame(width: viewSize.width, height: viewSize.height)
                    // Only the active page receives zoom + pan. Sibling
                    // pages stay at 1×, centred — they exist purely so
                    // the strip can scroll into view during a page swap.
                    .scaleEffect(idx == currentIndex ? scale : 1.0)
                    .offset(idx == currentIndex ? panOffset : .zero)
                    .clipped()
            }
        }
        .frame(width: viewSize.width, alignment: .leading)
        .offset(x: -CGFloat(currentIndex) * viewSize.width + pagerDragX)
    }

    @ViewBuilder
    private func photoContent(urlString: String) -> some View {
        if let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit()
                case .failure:
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.6))
                default:
                    ProgressView().tint(.white)
                }
            }
        } else {
            Image(systemName: "photo")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var controlsOverlay: some View {
        VStack {
            HStack {
                if photos.count > 1 {
                    Text("\(currentIndex + 1) / \(photos.count)")
                        .font(.custom("Inter", size: 12).weight(.heavy))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
                Spacer()
                Button(action: closeWithAnimation) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 56)

            Spacer()
        }
    }

    // MARK: - Magnification

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(0.6, lastScale * value)
            }
            .onEnded { _ in
                lastScale = scale
                if scale < 1.0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        scale = 1.0
                        lastScale = 1.0
                        panOffset = .zero
                        lastPanOffset = .zero
                    }
                } else if scale > 4.0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        scale = 4.0
                        lastScale = 4.0
                    }
                } else {
                    // Re-clamp pan to whatever the new scale's bounds allow.
                    panOffset = clampedPan(panOffset, scale: scale, viewSize: UIScreen.main.bounds.size)
                    lastPanOffset = panOffset
                }
            }
    }

    // MARK: - Drag

    private func dragGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in handleDragChanged(value, viewSize: viewSize) }
            .onEnded { value in handleDragEnded(value, viewSize: viewSize) }
    }

    private func handleDragChanged(_ value: DragGesture.Value, viewSize: CGSize) {
        let dx = value.translation.width
        let dy = value.translation.height

        // Decide the drag's mode the first time meaningful motion shows
        // up, then stick with it for the rest of the gesture so we can't
        // mid-drag switch from panning to dismissing etc.
        if dragMode == .undecided {
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 6 else { return }

            if isZoomed {
                dragMode = .panning
            } else if abs(dy) > abs(dx) * 1.2 {
                dragMode = .dismissing
            } else {
                dragMode = .paging
            }
        }

        switch dragMode {
        case .panning:
            applyPanDrag(dx: dx, dy: dy, viewSize: viewSize)
        case .paging:
            pagerDragX = dx
        case .dismissing:
            dismissOffsetY = dy
            let progress = min(abs(dy) / 300, 1.0)
            backgroundOpacity = 1.0 - progress * 0.5
        case .undecided:
            break
        }
    }

    /// Pan the zoomed image, and once we hit a horizontal boundary
    /// forward the *excess* drag distance to the pager. That's what
    /// gives the user a continuous gesture: pan to the edge of the
    /// image, then keep dragging, and the next/previous page slides in.
    private func applyPanDrag(dx: CGFloat, dy: CGFloat, viewSize: CGSize) {
        let bounds = panBounds(scale: scale, viewSize: viewSize)
        let proposedX = lastPanOffset.width + dx
        let proposedY = lastPanOffset.height + dy
        let clampedY = max(bounds.minY, min(bounds.maxY, proposedY))

        if proposedX > bounds.maxX {
            // Dragged past the right pan edge → showing more of the
            // image's left side wasn't possible, so the spare motion
            // pulls the previous page in from the left.
            panOffset = CGSize(width: bounds.maxX, height: clampedY)
            pagerDragX = proposedX - bounds.maxX
        } else if proposedX < bounds.minX {
            // Mirror of the above for the next page on the right.
            panOffset = CGSize(width: bounds.minX, height: clampedY)
            pagerDragX = proposedX - bounds.minX
        } else {
            panOffset = CGSize(width: proposedX, height: clampedY)
            pagerDragX = 0
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, viewSize: CGSize) {
        let dx = value.translation.width
        let dy = value.translation.height
        let predictedX = value.predictedEndTranslation.width
        let viewW = viewSize.width

        switch dragMode {
        case .panning:
            // If the pan's excess pulled the pager far enough (or fast
            // enough) to suggest a page change, commit it; otherwise
            // settle the pan at its clamped position.
            let pageThreshold = viewW / 4
            let predictThreshold = viewW / 2

            if pagerDragX > pageThreshold || (pagerDragX > 0 && predictedX > predictThreshold) {
                gotoIndex(currentIndex - 1, viewSize: viewSize)
            } else if pagerDragX < -pageThreshold || (pagerDragX < 0 && predictedX < -predictThreshold) {
                gotoIndex(currentIndex + 1, viewSize: viewSize)
            } else {
                lastPanOffset = panOffset
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    pagerDragX = 0
                }
            }
        case .paging:
            let pageThreshold = viewW / 3
            let predictThreshold = viewW / 2

            if dx < -pageThreshold || predictedX < -predictThreshold {
                gotoIndex(currentIndex + 1, viewSize: viewSize)
            } else if dx > pageThreshold || predictedX > predictThreshold {
                gotoIndex(currentIndex - 1, viewSize: viewSize)
            } else {
                snapPagerHome()
            }
        case .dismissing:
            if abs(dy) > 100 {
                isPresented = false
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    dismissOffsetY = 0
                    backgroundOpacity = 1.0
                }
            }
        case .undecided:
            break
        }

        dragMode = .undecided
    }

    /// Animate to the requested page if it's in range, otherwise snap
    /// the pager back home. Page changes always reset zoom and pan, so
    /// the next photo always opens at 1×.
    private func gotoIndex(_ newIndex: Int, viewSize: CGSize) {
        guard newIndex >= 0, newIndex < photos.count else {
            snapPagerHome()
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            currentIndex = newIndex
            scale = 1.0
            lastScale = 1.0
            panOffset = .zero
            lastPanOffset = .zero
            pagerDragX = 0
        }
    }

    private func snapPagerHome() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            pagerDragX = 0
        }
    }

    // MARK: - Helpers

    /// Allowed pan range for the current scale. We treat the viewport
    /// as the bounding box; for `scaledToFit` images this is generous
    /// in the unfilled axis (you can briefly pan past the actual image
    /// into letterbox space) but exact in the filled axis, which is the
    /// only one that matters for the edge-then-page gesture.
    private func panBounds(scale: CGFloat, viewSize: CGSize) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        let halfX = max(0, viewSize.width * (scale - 1) / 2)
        let halfY = max(0, viewSize.height * (scale - 1) / 2)
        return (-halfX, halfX, -halfY, halfY)
    }

    private func clampedPan(_ pan: CGSize, scale: CGFloat, viewSize: CGSize) -> CGSize {
        let b = panBounds(scale: scale, viewSize: viewSize)
        return CGSize(
            width: max(b.minX, min(b.maxX, pan.width)),
            height: max(b.minY, min(b.maxY, pan.height))
        )
    }

    private func handleDoubleTap() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if isZoomed {
                scale = 1.0
                lastScale = 1.0
                panOffset = .zero
                lastPanOffset = .zero
            } else {
                scale = 2.0
                lastScale = 2.0
            }
        }
    }

    private func closeWithAnimation() {
        withAnimation(.easeOut(duration: 0.2)) {
            isPresented = false
        }
    }
}

#Preview {
    PhotoGalleryViewer(
        photos: [
            "https://images.unsplash.com/photo-1532619675605-1ede6c2ed2b0?w=800&q=80",
            "https://images.unsplash.com/photo-1581094271901-8022df4466f9?w=800&q=80",
            "https://images.unsplash.com/photo-1606326608606-aa0b62935f2b?w=800&q=80",
        ],
        startIndex: 0,
        isPresented: .constant(true)
    )
}
