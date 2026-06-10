import SwiftUI

/// Navigation-stack hosted Task Detail screen. Pushed from ProfileView,
/// NotificationPanel (Insights bell flow), or any other route. Uses the
/// project's standard edge-swipe back gesture (`.enableSwipeBack`) so
/// dragging from the screen's left edge pops it.
///
/// Keeps the heavy presentation in `TaskDetailSheet` (renamed for legacy
/// reasons but acts as a pure rendering view). This wrapper:
///   - resolves the live task from the BigKid backend when this child owns
///     the paired device (`FamilyStore.ownsPairedDevice`); otherwise shows
///     the graceful missing-task fallback (no mock fixtures at runtime)
///   - performs Approve/Redo/Edit/Delete against the backend
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
    @Environment(FamilyStore.self) private var familyStore

    /// Live child from the family aggregate; nil when the id isn't in the
    /// store (HP-9 — no more silent `previewLiam` fallback).
    private var resolvedChild: ChildProfile? {
        familyStore.childProfiles.first(where: { $0.id == childId })
    }

    /// What we hand `TaskDetailSheet`. When the child can't be resolved,
    /// render neutral copy ("Your kid") instead of pretending it's Liam.
    private var displayChild: ChildProfile {
        resolvedChild ?? ChildProfile(
            id: childId, name: "Your kid", age: 0,
            avatarURL: nil, accentColor: .evPrimary, status: .unlocked,
            timeLeft: "", timePct: 0, subtitle: ""
        )
    }

    private var backendChildID: UUID? {
        guard familyStore.ownsPairedDevice(childId: childId,
                                           pairedDeviceID: pairedChildID) else { return nil }
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
                    child: displayChild,
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
                        // Local-only update; the backend poll re-syncs the
                        // authoritative row. (ProfileMockData is no longer a
                        // runtime store — tasks only exist for backend-backed
                        // children, see `reloadTask`.)
                        task = updated
                        editingTask = nil
                        reloadTask()
                    },
                    onDelete: {
                        // If this task lives in the BigKid backend (paired
                        // child), hit DELETE /parent/task/{id}. Without this
                        // branch the Profile UI was lying — local state
                        // cleared, but backend kept the task and the next 8s
                        // poll resurrected it on the row list.
                        if let backendID = activeEdit.backendID,
                           let client = bigKidParent {
                            Task {
                                do { try await client.deleteTask(taskId: backendID) } catch {
                                    print("[TaskDetail] delete failed: \(error)")
                                }
                                await MainActor.run {
                                    editingTask = nil
                                    onBack()
                                }
                            }
                        } else {
                            editingTask = nil
                            onBack()
                        }
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
        // No backend for this child → there are no real tasks to resolve.
        // Render the graceful missing-task fallback instead of resurrecting
        // ProfileMockData fixtures (item 9 — runtime path is fixture-free).
        task = nil
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
        // Non-backend fallback: local state only (no mock-store writes).
        var copy = t
        copy.state = (t.state == .bypass) ? .bypassed : .done
        task = copy
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
        // Non-backend fallback: local state only (no mock-store writes).
        var copy = t
        copy.state = .pending
        task = copy
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
