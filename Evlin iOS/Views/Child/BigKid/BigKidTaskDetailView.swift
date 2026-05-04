import SwiftUI

struct BigKidTaskDetailView: View {
    let task: BigKidTask
    var onBack: () -> Void
    var onBypass: () -> Void
    /// Submit the kid's working set of photos plus an optional note.
    /// The first element is the primary photo (parent sees it first in
    /// the carousel). The list REPLACES any existing evidence on the
    /// backend.
    var onSubmit: ([Data], String?) async -> Void

    @State private var note: String = ""
    /// Working set the kid is building up before tapping Submit. Empty
    /// during a fresh `.input`/`.redo` phase, or hydrated from on-disk
    /// cache after a successful submit.
    @State private var photos: [Data] = []
    @State private var showCamera = false
    @State private var submitting = false
    @FocusState private var noteFocused: Bool

    /// Hard cap matches the backend's `max 6 photos` guard so the kid
    /// can't queue an over-limit batch and only learn at submit time.
    private static let maxPhotos = 6

    /// Hydrate `photos` from the on-disk cache when the view appears so
    /// the kid sees their last submitted photos even after the backend's
    /// in-memory store gets wiped (which currently happens on every
    /// Railway redeploy). See `KidEvidenceCache`.
    private func hydrateFromCache() {
        if photos.isEmpty {
            let cached = KidEvidenceCache.load(taskId: task.id)
            if !cached.isEmpty { photos = cached }
        }
    }

    /// Stable scroll anchor for the note input. We scroll to this when the
    /// keyboard appears so the field doesn't sit under the keyboard. The
    /// system's automatic keyboard avoidance fails for axis: .vertical
    /// TextFields nested in a ScrollView — the avoidance shrinks the
    /// content area but doesn't scroll, so the field stays under the
    /// keyboard.
    private enum ScrollAnchor: Hashable { case noteField }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar.padding(.top, 8)
                    titleBlock.padding(.top, 12).padding(.bottom, 24)
                    if let due = task.due { dueRow(due).padding(.bottom, 24) }
                    whatToDoBlock.padding(.bottom, 24)
                    phaseContent
                }
                .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: noteFocused) { _, focused in
                guard focused else { return }
                // Two-step delay: wait for keyboard frame to register so
                // ScrollView knows the new safe-area inset before scrolling.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(ScrollAnchor.noteField, anchor: .bottom)
                    }
                }
            }
        }
        .background(EvlinKidColors.surface.ignoresSafeArea())
        .onAppear { hydrateFromCache() }
        .sheet(isPresented: $showCamera) {
            EvKidPhotoPicker { data in
                showCamera = false
                if let data, photos.count < Self.maxPhotos {
                    photos.append(data)
                }
            }
            .ignoresSafeArea()
        }
        // Tap-to-dismiss keyboard anywhere outside the field.
        .onTapGesture { noteFocused = false }
    }

    @ViewBuilder
    private var phaseContent: some View {
        // Status takes precedence over phase. Backend has no .done phase
        // (only input / submitted / redo), so once a parent approves,
        // status flips to .done while phase stays .submitted. Without
        // this check the kid would keep seeing "Evidence submitted –
        // waiting for parent" even after approval.
        if task.status == .done {
            approvedPhase
        } else {
            switch task.phase {
            case .input: inputPhase
            case .submitted: submittedPhase
            case .redo: redoPhase
            }
        }
    }

    // MARK: - Top bar
    private var topBar: some View {
        HStack {
            EvKidBackButton(label: "Today", action: onBack)
            Spacer()
            if task.phase == .input {
                Button(action: onBypass) {
                    Text("I couldn't do this")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(EvlinKidColors.ink3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(Capsule().stroke(EvlinKidColors.ink4, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Title
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            EvKidChip(task.category.rawValue, tone: chipTone)
            Text(task.title)
                .font(.system(size: 30, weight: .heavy))
                .tracking(EvlinKidMetrics.Letter.tightTitle)
                .foregroundStyle(EvlinKidColors.ink)
        }
    }

    private var chipTone: EvKidChip.Tone {
        switch task.category { case .chores: .violet; case .homework: .green; case .selfCare: .amber }
    }

    // MARK: - Due
    private func dueRow(_ due: String) -> some View {
        HStack {
            Text("DUE").font(.system(size: 13, weight: .bold))
                .tracking(0.8).foregroundStyle(EvlinKidColors.ink3)
            Spacer()
            Text("Today, \(due)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(task.status == .overdue ? Color(red: 200/255, green: 50/255, blue: 74/255) : EvlinKidColors.ink3)
        }
    }

    private var whatToDoBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT TO DO")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(EvlinKidColors.ink3)
            Text(task.description)
                .font(.system(size: 17))
                .foregroundStyle(EvlinKidColors.ink)
                .lineSpacing(4)
        }
    }

    // MARK: - Input phase
    private var inputPhase: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SHOW US")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(EvlinKidColors.ink3)
            cameraButton
            noteField
            EvKidBigButton(isDisabled: photos.isEmpty || submitting,
                           action: submitAction) {
                Text(submitting ? "Submitting…" : "Submit for approval")
            }
        }
    }

    /// Heroes the first photo and shows the rest as a thumbnail strip
    /// with an "+ Add" tile. Tap a thumbnail to remove it; tap the hero
    /// to retake the primary. When the kid hasn't taken any photos yet,
    /// degrades to the original single-tap "Take a photo" placeholder.
    @ViewBuilder
    private var cameraButton: some View {
        if photos.isEmpty {
            emptyCameraPlaceholder
        } else {
            VStack(spacing: 10) {
                if let primary = photos.first, let img = UIImage(data: primary) {
                    capturedPreview(uiImage: img)
                }
                photoStrip
                if photos.count >= Self.maxPhotos {
                    Text("Photo limit reached (\(Self.maxPhotos)).")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(EvlinKidColors.ink3)
                }
            }
        }
    }

    private var emptyCameraPlaceholder: some View {
        Button { showCamera = true } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(EvlinKidColors.green500)
                        .frame(width: 60, height: 60)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Take a photo")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(EvlinKidColors.ink2)
                Text("Show us what you did — you can add more after")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EvlinKidColors.ink3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(EvlinKidColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.cardLarge))
            .overlay(
                RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.cardLarge)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(EvlinKidColors.ink4)
            )
        }
        .buttonStyle(.plain)
    }

    /// Horizontal strip of every photo the kid has taken plus a trailing
    /// "+ Add" tile (hidden once we hit `maxPhotos`). Each thumbnail has
    /// a small X badge for removal. Indices are stable for the lifetime
    /// of this view instance so the kid's tap target doesn't shift while
    /// they're aiming for the X.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(photos.enumerated()), id: \.offset) { idx, data in
                    thumbnail(data: data, index: idx)
                }
                if photos.count < Self.maxPhotos {
                    addTile
                }
            }
            .padding(.vertical, 2) // give the X badge room to overflow
        }
    }

    private func thumbnail(data: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(index == 0 ? EvlinKidColors.primary : EvlinKidColors.line,
                                    lineWidth: index == 0 ? 2 : 1)
                    )
            }
            Button {
                photos.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white, .black.opacity(0.7))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove photo \(index + 1)")
        }
    }

    private var addTile: some View {
        Button { showCamera = true } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                Text("Add")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(EvlinKidColors.ink3)
            .frame(width: 72, height: 72)
            .background(EvlinKidColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .foregroundStyle(EvlinKidColors.ink4)
            )
        }
        .buttonStyle(.plain)
    }

    private func capturedPreview(uiImage: UIImage) -> some View {
        Button { showCamera = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.cardLarge))
                    .overlay(
                        RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.cardLarge)
                            .stroke(EvlinKidColors.primary, lineWidth: 2)
                    )

                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(photos.count >= Self.maxPhotos ? "Full" : "Add another")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(12)
            }
        }
        .buttonStyle(.plain)
        .disabled(photos.count >= Self.maxPhotos)
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EvlinKidColors.ink3)
            TextField("e.g. It took longer than I thought!", text: $note, axis: .vertical)
                .lineLimit(3...5)
                .font(.system(size: 16))
                .foregroundStyle(EvlinKidColors.ink)
                .focused($noteFocused)
                .submitLabel(.done)
                .padding(14)
                .background(EvlinKidColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(noteFocused ? EvlinKidColors.green500 : EvlinKidColors.line,
                                lineWidth: 1.5)
                )
        }
        .id(ScrollAnchor.noteField)
    }

    private func submitAction() {
        guard !photos.isEmpty else { return }
        submitting = true
        // Cache the bytes locally so this kid always sees their photos on
        // re-open, regardless of whether the backend kept its copies.
        // Saves before the network call so a slow upload doesn't lose
        // the cache if the user backgrounds the app mid-flight.
        KidEvidenceCache.save(taskId: task.id, photos: photos)
        let batch = photos
        Task {
            await onSubmit(batch, note.isEmpty ? nil : note)
            submitting = false
        }
    }

    // MARK: - Submitted phase
    private var submittedPhase: some View {
        VStack(alignment: .leading, spacing: 18) {
            EvKidCard(tone: .amber, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Evidence submitted")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(EvlinKidColors.primaryInk)
                    Text("Waiting for a parent to approve. You'll get a little ping when they do.")
                        .font(.system(size: 14))
                        .foregroundStyle(EvlinKidColors.amber)
                        .lineSpacing(2)
                    HStack(spacing: 10) {
                        ProgressView().tint(EvlinKidColors.amber)
                        Text("Sent just now")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(EvlinKidColors.amber)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(.white.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            evidencePreview.padding(.top, 4)
            EvKidBigButton(tone: .ghost, action: onBack) { Text("Back to today") }
        }
    }

    private var evidencePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("YOUR EVIDENCE")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(EvlinKidColors.ink3)
                Spacer()
                if evidenceTotalCount > 1 {
                    Text("\(evidenceTotalCount) photos")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(EvlinKidColors.ink3)
                }
            }
            evidenceContent
            if let note = task.evidenceNote, !note.isEmpty {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(EvlinKidColors.ink2)
                    .padding(.top, 4)
            }
        }
    }

    /// Total number of photos to display, prioritising local cached bytes
    /// (instant) over backend URLs (which arrive after the next state
    /// poll). The two are mirrors — the cache is written from the same
    /// list the kid just submitted.
    private var evidenceTotalCount: Int {
        if !photos.isEmpty { return photos.count }
        return task.evidencePhotoUrls.count
    }

    /// Hero + thumbnail strip for submitted/approved phases. Single
    /// photo collapses to just the hero (no strip).
    @ViewBuilder
    private var evidenceContent: some View {
        if !photos.isEmpty {
            evidenceFromLocalCache
        } else if !task.evidencePhotoUrls.isEmpty {
            evidenceFromBackend
        } else {
            placeholderImage
        }
    }

    @State private var evidenceFocusIndex: Int = 0

    private var evidenceFromLocalCache: some View {
        VStack(spacing: 10) {
            let idx = min(evidenceFocusIndex, photos.count - 1)
            if let img = UIImage(data: photos[idx]) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(4.0/3.0, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                placeholderImage
            }
            if photos.count > 1 {
                evidenceThumbStrip(count: photos.count) { i in
                    if let img = UIImage(data: photos[i]) {
                        Image(uiImage: img).resizable().scaledToFill()
                    }
                }
            }
        }
    }

    private var evidenceFromBackend: some View {
        VStack(spacing: 10) {
            let urls = task.evidencePhotoUrls
            let idx = min(evidenceFocusIndex, urls.count - 1)
            AsyncImage(url: urls[idx]) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .failure: placeholderImage
                case .empty:
                    ZStack { placeholderImage; ProgressView() }
                @unknown default: placeholderImage
                }
            }
            .aspectRatio(4.0/3.0, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            if urls.count > 1 {
                evidenceThumbStrip(count: urls.count) { i in
                    AsyncImage(url: urls[i]) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.gray.opacity(0.2)
                        }
                    }
                }
            }
        }
    }

    /// Thumb strip used by both local-cache and backend evidence views.
    /// Tapping a thumb sets `evidenceFocusIndex`, which the hero reads.
    @ViewBuilder
    private func evidenceThumbStrip<Thumb: View>(
        count: Int, @ViewBuilder thumb: @escaping (Int) -> Thumb
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { i in
                    Button { evidenceFocusIndex = i } label: {
                        thumb(i)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(i == evidenceFocusIndex
                                            ? EvlinKidColors.primary
                                            : EvlinKidColors.line,
                                            lineWidth: i == evidenceFocusIndex ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var placeholderImage: some View {
        ZStack {
            LinearGradient(
                colors: [EvlinKidColors.primarySoft, EvlinKidColors.green100],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(EvlinKidColors.ink4)
        }
        .aspectRatio(4.0/3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Approved phase
    /// Shown when status == .done. Two flavours:
    ///   - Normal approve (kid submitted evidence, parent approved):
    ///     celebratory "Approved!" with the photo + note.
    ///   - Bypass approve (kid asked to skip, parent allowed it):
    ///     softer "Excused" copy — no "thumbs up" framing because the
    ///     kid didn't actually do the work, plus the parent's reply if
    ///     they wrote one.
    private var approvedPhase: some View {
        let isBypassApproved = (task.bypass?.status == .approved)
        return VStack(alignment: .leading, spacing: 18) {
            EvKidCard(tone: .green, padding: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(EvlinKidColors.green500)
                                .frame(width: 36, height: 36)
                            Image(systemName: isBypassApproved ? "hand.raised.fill" : "checkmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Text(isBypassApproved ? "Excused" : "Approved!")
                            .font(.system(size: 19, weight: .heavy))
                            .foregroundStyle(EvlinKidColors.green700)
                    }
                    Text(isBypassApproved
                         ? "A parent agreed to let you skip this one. No worries."
                         : "Nice work — a parent reviewed it and gave it a thumbs up.")
                        .font(.system(size: 14))
                        .foregroundStyle(EvlinKidColors.green600)
                        .lineSpacing(2)
                    if isBypassApproved,
                       let reply = task.bypass?.parentResponse, !reply.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("FROM YOUR PARENT")
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(EvlinKidColors.green600)
                            Text(reply)
                                .font(.system(size: 14))
                                .foregroundStyle(EvlinKidColors.ink)
                                .lineSpacing(2)
                        }
                        .padding(12)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            // Bypass-approved tasks have no submitted photo — kid never
            // did the work — so skip evidencePreview in that branch.
            if !isBypassApproved {
                evidencePreview.padding(.top, 4)
            }
            EvKidBigButton(tone: .ghost, action: onBack) { Text("Back to today") }
        }
    }

    // MARK: - Redo phase
    /// Shown when a parent has clicked REQUEST REDO. Banner explains why,
    /// then the same camera + note + submit UI as the input phase so the
    /// kid can immediately take a new photo and resubmit. The previous
    /// version had a "Try again" button with an empty action and a stale
    /// comment claiming phase would flip on its own — it wouldn't, the
    /// kid was stuck.
    private var redoPhase: some View {
        VStack(alignment: .leading, spacing: 18) {
            EvKidCard(tone: .amber, padding: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Let's try that again")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(EvlinKidColors.primaryInk)
                    Text("A parent sent this back. No stress — have another go.")
                        .font(.system(size: 14))
                        .foregroundStyle(EvlinKidColors.amber)
                        .lineSpacing(2)
                    if let reason = task.redoReason {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOTE FROM YOUR PARENT")
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(EvlinKidColors.amber)
                            Text(reason)
                                .font(.system(size: 15))
                                .foregroundStyle(EvlinKidColors.ink)
                                .lineSpacing(2)
                        }
                        .padding(14)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(EvlinKidColors.green200, lineWidth: 1)
                        )
                    }
                }
            }
            // Reuse the input UI so the kid can immediately retake a
            // photo + add a new note + resubmit. Same hookup as the
            // initial submission — submitAction calls onSubmit which
            // hits POST /child/task/{id}/evidence.
            inputPhase
        }
    }
}

#if DEBUG
#Preview("Input") {
    BigKidTaskDetailView(task: .fixture(status: .todo, phase: .input),
                         onBack: {}, onBypass: {}, onSubmit: { (_: [Data], _: String?) in })
}
#Preview("Submitted") {
    BigKidTaskDetailView(task: .fixture(status: .submitted, phase: .submitted),
                         onBack: {}, onBypass: {}, onSubmit: { (_: [Data], _: String?) in })
}
private func _redoPreviewTask() -> BigKidTask {
    let t = BigKidTask.fixture(status: .todo, phase: .redo)
    return BigKidTask(id: t.id, title: t.title, description: t.description,
                      category: t.category, due: t.due, status: t.status, phase: t.phase,
                      redoReason: "Bed is still messy. Please smooth the covers.",
                      evidencePhotoUrls: [], evidenceNote: nil, bypass: nil)
}
#Preview("Redo") {
    BigKidTaskDetailView(task: _redoPreviewTask(),
                         onBack: {}, onBypass: {}, onSubmit: { (_: [Data], _: String?) in })
}
#endif
