import Foundation

/// One SSE event: `event:` name + joined `data:` payload.
struct SSEEvent: Equatable {
    let event: String
    let data: String
}

/// Incremental SSE framing: feed lines (already split on \n by
/// URLSession.bytes.lines), get an event back on each blank-line terminator.
struct SSELineParser {
    private var event: String?
    private var dataLines: [String] = []

    mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { event = nil; dataLines = [] }
            guard let e = event else { return nil }
            return SSEEvent(event: e, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }              // comment/heartbeat
        if line.hasPrefix("event: ") { event = String(line.dropFirst(7)); return nil }
        if line.hasPrefix("data: ") { dataLines.append(String(line.dropFirst(6))); return nil }
        return nil
    }
}

/// Typed chat events per spec §3. Unknown event names → nil (forward compat).
enum ChatStreamEvent: Equatable {
    case stage(key: String, label: String)
    case textDelta(String)
    case envelope(Data)
    case error(message: String)

    static func parse(_ raw: SSEEvent) -> ChatStreamEvent? {
        let data = Data(raw.data.utf8)
        switch raw.event {
        case "stage":
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let key = obj["key"], let label = obj["label"] else { return nil }
            return .stage(key: key, label: label)
        case "text_delta":
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let t = obj["t"] else { return nil }
            return .textDelta(t)
        case "envelope":
            return .envelope(data)
        case "error":
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return .error(message: (obj?["message"] as? String) ?? "stream error")
        default:
            return nil
        }
    }
}
