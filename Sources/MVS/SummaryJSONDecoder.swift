import Foundation

enum SummaryJSONDecoder {
    static func decode(from text: String) throws -> SummaryResult {
        let cleaned = clean(text)
        let candidates = [balancedJSONObject(in: cleaned), cleaned].compactMap { $0 }

        for candidate in candidates {
            if let decoded = tryDecodeStrict(candidate) {
                return decoded
            }
        }

        if let repaired = repairSummary(from: cleaned) {
            return repaired
        }

        let preview = cleaned.prefix(1000)
        throw MVSError.processFailed("Summary JSON could not be decoded or repaired. Output: \(preview)")
    }

    private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = value
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func tryDecodeStrict(_ value: String) -> SummaryResult? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SummaryResult.self, from: data)
    }

    private static func balancedJSONObject(in value: String) -> String? {
        guard let start = value.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaping = false
        var index = start

        while index < value.endIndex {
            let char = value[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(value[start...index])
                    }
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func repairSummary(from value: String) -> SummaryResult? {
        let summary = extractString(key: "summary", from: value)
        let timeline = extractArray(key: "timeline", from: value)
        let keyDecisions = extractArray(key: "keyDecisions", from: value)
        let actionItems = extractArray(key: "actionItems", from: value)
        let keywords = extractArray(key: "keywords", from: value)

        let hasContent = [summary].contains { !$0.isEmpty }
            || [timeline, keyDecisions, actionItems, keywords].contains { !$0.isEmpty }
        guard hasContent else { return nil }

        return SummaryResult(
            summary: summary.isEmpty ? "Summary response was partially recovered from malformed JSON." : summary,
            timeline: timeline,
            keyDecisions: keyDecisions,
            actionItems: actionItems,
            keywords: keywords
        )
    }

    private static func extractString(key: String, from value: String) -> String {
        let pattern = #""\#(NSRegularExpression.escapedPattern(for: key))"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let match = firstMatch(pattern: pattern, in: value), match.numberOfRanges > 1 else {
            return ""
        }
        return unescapeJSONString(String(value[Range(match.range(at: 1), in: value)!]))
    }

    private static func extractArray(key: String, from value: String) -> [String] {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #""\#(escapedKey)"\s*:\s*\[([\s\S]*?)(?:\]\s*,?|\n\s*"[A-Za-z][A-Za-z0-9]*"\s*:|\z)"#
        guard let match = firstMatch(pattern: pattern, in: value), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return []
        }
        return quotedStrings(in: String(value[range]))
    }

    private static func quotedStrings(in value: String) -> [String] {
        let pattern = #""((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: value) else {
                return nil
            }
            let item = unescapeJSONString(String(value[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            return item.isEmpty ? nil : item
        }
    }

    private static func firstMatch(pattern: String, in value: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range)
    }

    private static func unescapeJSONString(_ value: String) -> String {
        let wrapped = "[\"\(value)\"]"
        if let data = wrapped.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String],
           let first = array.first {
            return first
        }
        return value
            .replacingOccurrences(of: #"\""#, with: #"""#)
            .replacingOccurrences(of: #"\\n"#, with: "\n")
            .replacingOccurrences(of: #"\\/"#, with: "/")
    }
}
