import Foundation

enum SubtitleParser {
    static func parse(_ content: String, format: String) throws -> TranscriptResult {
        if format.lowercased() == "json3" {
            let object = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
            let segments = (object?["events"] as? [[String: Any]] ?? []).enumerated().compactMap { index, event -> TranscriptSegment? in
                guard let start = event["tStartMs"] as? Double,
                      let duration = event["dDurationMs"] as? Double,
                      let pieces = event["segs"] as? [[String: Any]] else { return nil }
                let text = clean(pieces.compactMap { $0["utf8"] as? String }.joined())
                guard !text.isEmpty, start >= 0, duration > 0 else { return nil }
                return TranscriptSegment(id: "subtitle-\(index)", start: start / 1000, end: (start + duration) / 1000, speaker: nil, text: text)
            }
            return result(segments)
        }

        let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var segments: [TranscriptSegment] = []
        var start: Double?
        var end: Double?
        var textLines: [String] = []
        func flush() {
            let text = clean(textLines.joined(separator: " "))
            if let start, let end, end > start, !text.isEmpty {
                segments.append(TranscriptSegment(id: "subtitle-\(segments.count)", start: start, end: end, speaker: nil, text: text))
            }
            start = nil
            end = nil
            textLines = []
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flush()
            } else if line.contains("-->") {
                flush()
                let times = line.components(separatedBy: "-->")
                start = timestamp(times[0])
                end = times.count == 2 ? timestamp(times[1]) : nil
            } else if start != nil {
                // Numeric cue text is content; cue identifiers occur before timing lines.
                textLines.append(line)
            }
        }
        flush()
        return result(segments)
    }

    static func covers(_ transcript: TranscriptResult, duration: Double?) -> Bool {
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let intervals = transcript.segments.compactMap { segment -> (Double, Double)? in
            guard let start = segment.start, let end = segment.end,
                  start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return (start, end)
        }.sorted { $0.0 < $1.0 }
        guard let first = intervals.first, let lastEnd = intervals.map(\.1).max() else { return false }
        guard let duration, duration.isFinite, duration > 0 else { return true }
        var covered = 0.0
        var previousEnd = first.0
        for (start, end) in intervals {
            covered += max(0, min(end, duration) - max(start, previousEnd))
            previousEnd = max(previousEnd, end)
        }
        // Require both a useful span and cue coverage; a lone cue at the end is not a transcript.
        return first.0 <= max(15, duration * 0.15)
            && lastEnd >= duration * 0.85
            && covered >= duration * 0.35
    }

    static func rank(_ name: String) -> Int {
        let value = name.lowercased()
        if value.contains("zh-hans") || value.contains("zh-cn") { return 0 }
        if value == "zh" || value.contains(".zh.") { return 1 }
        if value.contains("zh-hant") || value.contains("zh-tw") || value.contains("zh-hk") { return 2 }
        if value.hasPrefix("en") || value.contains(".en.") || value.contains(".en-") { return 3 }
        return 4
    }

    private static func timestamp(_ raw: String) -> Double? {
        guard let token = raw.split(whereSeparator: \.isWhitespace).first else { return nil }
        let parts = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var result = 0.0
        for part in parts {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            result = result * 60 + value
        }
        return result
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func result(_ segments: [TranscriptSegment]) -> TranscriptResult {
        var unique: [TranscriptSegment] = []
        for segment in segments {
            if let previous = unique.last, previous.text == segment.text,
               let end = previous.end, let start = segment.start, start <= end + 0.1 {
                unique[unique.count - 1] = TranscriptSegment(id: previous.id, start: previous.start, end: segment.end, speaker: nil, text: previous.text)
            } else {
                unique.append(segment)
            }
        }
        return TranscriptResult(text: unique.map(\.text).joined(separator: "\n"), segments: unique)
    }
}
