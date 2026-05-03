import SwiftUI

/// Navigation-stack hosted Task Detail screen. Pushed from ProfileView,
/// NotificationPanel (Insights bell flow), or any other route. Uses the
/// project's standard edge-swipe back gesture (`.enableSwipeBack`) so
/// dragging from the screen's left edge pops it.
///
/// Keeps the heavy presentation in `TaskDetailSheet` (renamed for legacy
/// reasons but acts as a pure rendering view). This wrapper:
///   - resolves the live task from `ProfileMockData.runtimeTasks`
///   - mutates that store on Approve/Redo/Edit/Delete
///   - hosts the in-place EditTaskCard modal (no native sheet)
struct TaskDetailView: View {
    let childId: String
    let taskId: Int
    var onBack: () -> Void = {}

    @State private var task: TaskItem? = nil
    @State private var editingTask: TaskItem? = nil
    @State private var showFullscreenPhoto: Bool = false
    @State private var fullscreenStartIndex: Int = 0
    @State private var backendError: String? = nil

    @AppStorage("evlin.childDeviceID") private var pairedChildID: String = ""
    @EnvironmentObject private var apiClient: APIClient

    private var resolvedChild: ChildProfile {
        ChildProfile.all.first(where: { $0.id == childId }) ?? .liam
    }

    private var backendChildID: UUID? {
        guard childId == "liam", !pairedChildID.isEmpty else { return nil }
        return UUID(uuidString: pairedChildID)
    }
    private var bigKidParent: BigKidParentClient? {
        guard backendChildID != nil else { return nil }
        return BigKidParentClient(baseURLString: apiClient.baseURL)
    }

    var body: some View {
        ZStack {
            if let liveTask = task {
                TaskDetailSheet(
                    task: liveTask,
                    child: resolvedChild,
                    onClose: onBack,
                    onApprove: {
                        approve(liveTask)
                    },
                    onRedo: {
                        redo(liveTask)
                    },
                    onEdit: {
                        editingTask = liveTask
                    },
                    onPhotoTap: { idx in
                        fullscreenStartIndex = idx
                        showFullscreenPhoto = true
                    }
                )
            } else {
                // Lost task (e.g. deleted from elsewhere): fall back to
                // a graceful empty screen with a back button.
                missingTaskFallback
            }
        }
        .background(Color.evSurface)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .onAppear { reloadTask() }
        // Edit Task lives inside TaskDetail itself (not on the parent
        // ProfileView) so the modal renders above this screen even
        // after we deep-link in via NotificationPanel.
        .overlay {
            EvlinSheetCardItem(item: $editingTask) { activeEdit in
                EditTaskForm(
                    task: activeEdit,
                    onSave: { updated in
                        ProfileMockData.updateTask(updated, for: childId)
                        editingTask = nil
                        reloadTask()
                    },
                    onDelete: {
                        ProfileMockData.deleteTask(activeEdit.id, for: childId)
                        editingTask = nil
                        onBack()
                    },
                    onCancel: { editingTask = nil }
                )
            }
        }
        .fullScreenCover(isPresented: $showFullscreenPhoto) {
            if let urls = task?.photos, !urls.isEmpty {
                PhotoGalleryViewer(
                    photos: urls,
                    startIndex: fullscreenStartIndex,
                    isPresented: $showFullscreenPhoto
                )
            }
        }
    }

    // MARK: - Mutations

    private func reloadTask() {
        // Backend path (Liam, paired): hit /parent/state and pick the row
        // that maps to our `taskId`. We re-derive `sequenceID` the same way
        // ProfileView does so deep-link IDs round-trip stably as long as
        // the task list order is preserved between fetches.
        if let cid = backendChildID, let client = bigKidParent {
            Task {
                do {
                    let snapshot = try await client.fetchKidState(childId: cid)
                    let mapped = snapshot.tasks.enumerated().map { idx, t in
                        TaskItem.from(backend: t, sequenceID: idx + 1)
                    }
                    await MainActor.run {
                        task = mapped.first(where: { $0.id == taskId })
                        backendError = nil
                    }
                } catch {
                    await MainActor.run {
                        backendError = (error as? BigKidAPIError).map(\.detail)
                            ?? error.localizedDescription
                    }
                }
            }
            return
        }
        let list = ProfileMockData.tasks(for: childId)
        task = list.first(where: { $0.id == taskId })
    }

    private func approve(_ t: TaskItem) {
        if let backendID = t.backendID, let client = bigKidParent {
            // Optimistic flip
            var copy = t
            copy.state = (t.state == .bypass) ? .bypassed : .done
            task = copy
            Task {
                do {
                    if t.state == .bypass, let bid = t.backendBypassID {
                        _ = try await client.respondBypass(
                            bypassId: bid, decision: .approve, message: nil
                        )
                    } else {
                        _ = try await client.reviewTask(taskId: backendID, decision: .approve)
                    }
                    reloadTask()
                } catch {
                    await MainActor.run {
                        backendError = "approve failed: \(error.localizedDescription)"
                    }
                    reloadTask()
                }
            }
            return
        }
        var copy = t
        copy.state = (t.state == .bypass) ? .bypassed : .done
        ProfileMockData.updateTask(copy, for: childId)
        reloadTask()
    }

    private func redo(_ t: TaskItem) {
        if let backendID = t.backendID, let client = bigKidParent {
            var copy = t
            copy.state = .pending
            task = copy
            Task {
                do {
                    if t.state == .bypass, let bid = t.backendBypassID {
                        _ = try await client.respondBypass(
                            bypassId: bid, decision: .deny, message: nil
                        )
                    } else {
                        _ = try await client.reviewTask(
                            taskId: backendID, decision: .redo, redoReason: nil
                        )
                    }
                    reloadTask()
                } catch {
                    await MainActor.run {
                        backendError = "redo failed: \(error.localizedDescription)"
                    }
                    reloadTask()
                }
            }
            return
        }
        var copy = t
        copy.state = .pending
        ProfileMockData.updateTask(copy, for: childId)
        reloadTask()
    }

    // MARK: - Fallback

    private var missingTaskFallback: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("This task is no longer available.")
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Button("Back", action: onBack)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
