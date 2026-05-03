import SwiftUI

struct BigKidTaskDetailView: View {
    let task: BigKidTask
    var onBack: () -> Void
    var onBypass: () -> Void
    var onSubmit: (Data, String?) async -> Void

    @State private var note: String = ""
    @State private var photoData: Data?
    @State private var showCamera = false
    @State private var submitting = false

    var body: some View {
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
        .background(EvlinKidColors.surface.ignoresSafeArea())
        .sheet(isPresented: $showCamera) {
            EvKidPhotoPicker { data in
                showCamera = false
                if let data { photoData = data }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch task.phase {
        case .input: inputPhase
        case .submitted: submittedPhase
        case .redo: redoPhase
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
            EvKidBigButton(isDisabled: photoData == nil || submitting,
                           action: submitAction) {
                Text(submitting ? "Submitting…" : "Submit for approval")
            }
        }
    }

    @ViewBuilder
    private var cameraButton: some View {
        if let data = photoData, let uiImage = UIImage(data: data) {
            capturedPreview(uiImage: uiImage)
        } else {
            emptyCameraPlaceholder
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
                Text("Show us what you did")
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
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Tap to retake")
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
                .padding(14)
                .background(EvlinKidColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(EvlinKidColors.line, lineWidth: 1.5)
                )
        }
    }

    private func submitAction() {
        guard let data = photoData else { return }
        submitting = true
        Task {
            await onSubmit(data, note.isEmpty ? nil : note)
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
            Text("YOUR EVIDENCE")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(EvlinKidColors.ink3)
            // Show actual photo if cached locally; else placeholder
            placeholderImage
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

    // MARK: - Redo phase
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
            EvKidBigButton(action: { /* phase will flip on next poll once parent re-reviews */ }) {
                Text("Try again")
            }
        }
    }
}

#if DEBUG
#Preview("Input") {
    BigKidTaskDetailView(task: .fixture(status: .todo, phase: .input),
                         onBack: {}, onBypass: {}, onSubmit: { _, _ in })
}
#Preview("Submitted") {
    BigKidTaskDetailView(task: .fixture(status: .submitted, phase: .submitted),
                         onBack: {}, onBypass: {}, onSubmit: { _, _ in })
}
#Preview("Redo") {
    var t = BigKidTask.fixture(status: .todo, phase: .redo)
    t = BigKidTask(id: t.id, title: t.title, description: t.description,
                   category: t.category, due: t.due, status: t.status, phase: t.phase,
                   redoReason: "Bed is still messy. Please smooth the covers.",
                   evidencePhotoURL: nil, bypass: nil)
    return BigKidTaskDetailView(task: t, onBack: {}, onBypass: {}, onSubmit: { _, _ in })
}
#endif
