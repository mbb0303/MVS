import Foundation

enum ChineseTextConverter {
    static func traditionalToSimplified(_ value: String) -> String {
        let mutable = NSMutableString(string: value)
        CFStringTransform(mutable as CFMutableString, nil, "Traditional-Simplified" as CFString, false)
        return mutable as String
    }
}

extension TranscriptResult {
    func convertedTraditionalChineseToSimplified() -> TranscriptResult {
        TranscriptResult(
            text: ChineseTextConverter.traditionalToSimplified(text),
            segments: segments.map { segment in
                TranscriptSegment(
                    id: segment.id,
                    start: segment.start,
                    end: segment.end,
                    speaker: segment.speaker,
                    text: ChineseTextConverter.traditionalToSimplified(segment.text)
                )
            }
        )
    }
}
