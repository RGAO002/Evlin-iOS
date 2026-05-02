import SwiftUI

#if DEBUG
struct BigKidDevHarnessView: View {
    @StateObject private var client = BigKidAPIClient(
        baseURL: URL(string: "http://localhost:8000/api/v1")!,
        childId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
    @State private var state = BigKidState(snapshot: .fixture())
    @State private var poller: BigKidStatePoller?
    @State private var raw: String = "(loading…)"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("BigKid dev harness").font(.title2).bold()
                Text("Tasks: \(state.tasks.count)")
                Text("Minutes left: \(state.minutesLeft) / \(state.minutesMax)")
                Text("All tasks done: \(state.allTasksDone ? "YES" : "no")")
                Text("Reflection: \(state.reflectionRequest?.status.rawValue ?? "none")")
                Divider()
                Text(raw).font(.system(size: 11, design: .monospaced))
            }
            .padding()
        }
        .task {
            let p = BigKidStatePoller(client: client, state: state)
            poller = p
            p.start()
        }
        .task {
            do {
                let snapshot = try await client.fetchState()
                let data = try JSONEncoder.bigKid.encode(snapshot)
                raw = String(data: data, encoding: .utf8) ?? "<decode failed>"
            } catch {
                raw = "ERROR: \(error)"
            }
        }
    }
}

#Preview { BigKidDevHarnessView() }
#endif
