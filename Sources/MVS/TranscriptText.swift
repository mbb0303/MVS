import Foundation

enum TranscriptText {
    static func render(_ transcript: TranscriptResult) -> String {
        let segmentText = transcript.segments.map(\.text).joined(separator: "\n")
        func comparable(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines).joined()
        }
        guard !transcript.segments.isEmpty,
              comparable(segmentText) == comparable(transcript.text) else { return transcript.text }
        return transcript.segments.map { segment in
            var prefix = ""
            if let start = segment.start, start.isFinite, start >= 0, start < 1_000_000_000 {
                let seconds = Int(start)
                prefix = String(format: "[%02d:%02d:%02d] ", seconds / 3600, seconds / 60 % 60, seconds % 60)
            }
            if let speaker = segment.speaker { prefix += "\(speaker): " }
            return prefix + segment.text
        }.joined(separator: "\n\n")
    }

    static func chunks(_ text: String, limit: Int) -> [String] {
        precondition(limit > 0)
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}
