import Foundation

/// Headline above the embedded reflection clip. For Rick Roll demos the **backend**
/// now sends Gemini's `video_title` (`videoLessonTitle`); older builds only had generic
/// copy — we substitute from `displayReason`/`reason` when those stale strings appear.
enum ReflectionVideoDisplay {

    static let rickRollVideoId = "dQw4w9WgXcQ"

    /// Upper title on the reflection video step — **not** the literal YouTube track name when we
    /// deliberately use Rick Roll as the clip.
    static func cardTitle(for request: ReflectionRequest) -> String {
        cardTitle(
            videoId: request.videoId,
            serverTitle: request.videoTitle,
            displayReason: request.displayReason,
            rawReason: request.reason
        )
    }

    static func cardTitle(
        videoId: String,
        serverTitle: String,
        displayReason: String?,
        rawReason: String
    ) -> String {
        let trimmedDisplay = displayReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRaw = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)

        if videoId == rickRollVideoId {
            let st = serverTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !st.isEmpty && !isStaleServerVideoLessonTitle(st) {
                return capLength(stripTerminalPeriod(st))
            }
            if !trimmedDisplay.isEmpty {
                return headlineFromReflectionBody(trimmedDisplay)
            }
            if !trimmedRaw.isEmpty {
                return headlineFromReflectionBody(heuristicKidLine(fromRawReason: trimmedRaw))
            }
            return fallbackTitle(trimmedDisplay: trimmedDisplay, trimmedRaw: trimmedRaw, serverTitle: serverTitle)
        }

        if !serverTitle.isEmpty { return serverTitle }
        return fallbackTitle(trimmedDisplay: trimmedDisplay, trimmedRaw: trimmedRaw, serverTitle: serverTitle)
    }

    private static func fallbackTitle(
        trimmedDisplay: String,
        trimmedRaw: String,
        serverTitle: String
    ) -> String {
        if !trimmedDisplay.isEmpty { return headlineFromReflectionBody(trimmedDisplay) }
        if !trimmedRaw.isEmpty { return headlineFromReflectionBody(heuristicKidLine(fromRawReason: trimmedRaw)) }
        if !serverTitle.isEmpty { return serverTitle }
        return "A short clip to think about"
    }

    /// Old seed / fallback JSON before Gemini supplied `videoLessonTitle`.
    private static func isStaleServerVideoLessonTitle(_ serverTitle: String) -> Bool {
        let lower = serverTitle.lowercased()
        if lower.contains("why rest time matters") { return true }
        if lower.contains("(placeholder)") { return true }
        if lower.contains("rick roll") && lower.contains("placeholder") { return true }
        if lower.contains("fixture") && (lower.contains("no gemini") || lower.contains("(fixture")) {
            return true
        }
        return false
    }

    /// Gemini / parent narration → concise heading (sentence-case, truncated).
    private static func headlineFromReflectionBody(_ body: String) -> String {
        let collapsed = body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "A short clip to think about" }

        if let range = collapsed.range(of: ". ") {
            let first = String(collapsed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if first.count >= 8 { return capLength(stripTerminalPeriod(first)) }
        }

        let single = stripTerminalPeriod(collapsed)
        return capLength(single)
    }

    private static func stripTerminalPeriod(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("."), t.count > 1 {
            t.removeLast()
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    private static func capLength(_ s: String, max: Int = 88) -> String {
        guard s.count > max else { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        var prefix = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
        if let lastSpace = prefix.lastIndex(of: " ") {
            prefix = String(prefix[..<lastSpace])
        }
        return prefix + "…"
    }

    private static func heuristicKidLine(fromRawReason raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 2 { return t }
        if t.lowercased().hasPrefix("you ") { return t }
        return "Thinking about what happened: \(t)"
    }
}
