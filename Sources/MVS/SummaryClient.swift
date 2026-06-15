import Foundation

@MainActor
final class SummaryClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func summarize(transcript: TranscriptResult, title: String, source: VideoSourceKind, settings: SettingsStore) async throws -> SummaryResult {
        if transcript.text.count > 24_000 || transcript.segments.count > 350 {
            return try await summarizeLongTranscript(transcript: transcript, title: title, source: source, settings: settings)
        }
        return try await summarizeDirect(transcript: transcript, title: title, source: source, settings: settings)
    }

    private func summarizeDirect(transcript: TranscriptResult, title: String, source: VideoSourceKind, settings: SettingsStore) async throws -> SummaryResult {
        switch settings.summaryProvider {
        case .openAI:
            return try await summarizeWithOpenAI(transcript: transcript, title: title, source: source, model: settings.summaryModel)
        case .deepSeek:
            return try await summarizeWithDeepSeek(transcript: transcript, title: title, source: source, model: settings.summaryModel)
        case .bailianQwen:
            return try await summarizeWithBailianQwen(transcript: transcript, title: title, source: source, model: settings.summaryModel)
        }
    }

    private func summarizeLongTranscript(transcript: TranscriptResult, title: String, source: VideoSourceKind, settings: SettingsStore) async throws -> SummaryResult {
        let chunks = transcriptChunks(transcript, maxCharacters: 18_000)
        var partials: [SummaryResult] = []
        for (index, chunk) in chunks.enumerated() {
            let partTitle = "\(title) · part \(index + 1)/\(chunks.count)"
            partials.append(try await summarizeDirect(transcript: chunk, title: partTitle, source: source, settings: settings))
        }
        let combinedText = partials.enumerated().map { index, item in
            """
            PART \(index + 1)
            Summary: \(item.summary)
            Timeline:
            \(item.timeline.joined(separator: "\n"))
            Key decisions:
            \(item.keyDecisions.joined(separator: "\n"))
            Action items:
            \(item.actionItems.joined(separator: "\n"))
            Keywords: \(item.keywords.joined(separator: ", "))
            """
        }.joined(separator: "\n\n")
        let combined = TranscriptResult(
            text: combinedText,
            segments: partials.enumerated().map { index, item in
                TranscriptSegment(id: "summary-part-\(index)", start: nil, end: nil, speaker: nil, text: item.summary)
            }
        )
        return try await summarizeDirect(transcript: combined, title: "\(title) · combined summary", source: source, settings: settings)
    }

    private func transcriptChunks(_ transcript: TranscriptResult, maxCharacters: Int) -> [TranscriptResult] {
        if !transcript.segments.isEmpty {
            var chunks: [TranscriptResult] = []
            var current: [TranscriptSegment] = []
            var count = 0
            for segment in transcript.segments {
                let nextCount = count + segment.text.count
                if !current.isEmpty && nextCount > maxCharacters {
                    chunks.append(TranscriptResult(text: current.map(\.text).joined(separator: "\n"), segments: current))
                    current = []
                    count = 0
                }
                current.append(segment)
                count += segment.text.count
            }
            if !current.isEmpty {
                chunks.append(TranscriptResult(text: current.map(\.text).joined(separator: "\n"), segments: current))
            }
            return chunks
        }

        var chunks: [TranscriptResult] = []
        var start = transcript.text.startIndex
        while start < transcript.text.endIndex {
            let end = transcript.text.index(start, offsetBy: maxCharacters, limitedBy: transcript.text.endIndex) ?? transcript.text.endIndex
            let text = String(transcript.text[start..<end])
            chunks.append(TranscriptResult(text: text, segments: []))
            start = end
        }
        return chunks.isEmpty ? [transcript] : chunks
    }

    private func summarizePrompt(transcript: TranscriptResult, title: String, source: VideoSourceKind) -> String {
        """
        You are summarizing a video or online meeting for a local MVS knowledge library.
        Follow the source language. If the transcript is multilingual, summarize in the dominant language.
        Return strict JSON with exactly these keys:
        - summary: string
        - timeline: array of concise chapter bullets with timestamps if available, at most 12 items
        - keyDecisions: array of key conclusions or decisions, at most 8 items
        - actionItems: array of action items, each including owner/deadline if mentioned, at most 8 items
        - keywords: array of 5 to 12 searchable keywords
        Return one complete JSON object only. Do not truncate the JSON. Keep each item concise.

        Source: \(source.rawValue)
        Title: \(title)

        Transcript:
        \(transcript.text)
        """
    }

    private func summarizeWithOpenAI(transcript: TranscriptResult, title: String, source: VideoSourceKind, model: String) async throws -> SummaryResult {
        let body: [String: Any] = [
            "model": model,
            "input": summarizePrompt(transcript: transcript, title: title, source: source),
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "mvs_summary",
                    "schema": summarySchema()
                ]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await validatedData(for: request, providerName: "OpenAI")
        let outputText = try extractOpenAIOutputText(from: data)
        return try decodeSummary(from: outputText)
    }

    private func summarizeWithDeepSeek(transcript: TranscriptResult, title: String, source: VideoSourceKind, model: String) async throws -> SummaryResult {
        try await summarizeWithChatCompletions(
            transcript: transcript,
            title: title,
            source: source,
            model: model,
            endpoint: "https://api.deepseek.com/chat/completions",
            providerName: "DeepSeek"
        )
    }

    private func summarizeWithBailianQwen(transcript: TranscriptResult, title: String, source: VideoSourceKind, model: String) async throws -> SummaryResult {
        try await summarizeWithChatCompletions(
            transcript: transcript,
            title: title,
            source: source,
            model: model,
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            providerName: "Alibaba Bailian Qwen"
        )
    }

    private func summarizeWithChatCompletions(
        transcript: TranscriptResult,
        title: String,
        source: VideoSourceKind,
        model: String,
        endpoint: String,
        providerName: String
    ) async throws -> SummaryResult {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "You return only valid JSON. Do not include markdown fences or explanatory prose."
                ],
                [
                    "role": "user",
                    "content": summarizePrompt(transcript: transcript, title: title, source: source)
                ]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.1,
            "max_tokens": 4096,
            "stream": false
        ]

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await validatedData(for: request, providerName: providerName)
        let outputText = try extractChatCompletionText(from: data, providerName: providerName)
        do {
            return try decodeSummary(from: outputText)
        } catch {
            let repaired = try await repairChatCompletionJSON(
                malformed: outputText,
                endpoint: endpoint,
                providerName: providerName,
                model: model
            )
            return try decodeSummary(from: repaired)
        }
    }

    private func repairChatCompletionJSON(malformed: String, endpoint: String, providerName: String, model: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "Repair malformed JSON. Return one complete JSON object only, with keys summary, timeline, keyDecisions, actionItems, keywords."
                ],
                [
                    "role": "user",
                    "content": malformed
                ]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0,
            "max_tokens": 4096,
            "stream": false
        ]
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await validatedData(for: request, providerName: providerName)
        return try extractChatCompletionText(from: data, providerName: providerName)
    }

    private func summarySchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "summary": ["type": "string"],
                "timeline": ["type": "array", "items": ["type": "string"]],
                "keyDecisions": ["type": "array", "items": ["type": "string"]],
                "actionItems": ["type": "array", "items": ["type": "string"]],
                "keywords": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["summary", "timeline", "keyDecisions", "actionItems", "keywords"]
        ]
    }

    private func validatedData(for request: URLRequest, providerName: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MVSError.openAIResponse("Missing HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw MVSError.openAIResponse("\(providerName): \(message)")
        }
        return data
    }

    private func extractOpenAIOutputText(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let outputText = object?["output_text"] as? String {
            return outputText
        }
        if let output = object?["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for block in content {
                    if let text = block["text"] as? String {
                        return text
                    }
                }
            }
        }
        throw MVSError.openAIResponse("Responses API output did not contain text.")
    }

    private func extractChatCompletionText(from data: Data, providerName: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = object?["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MVSError.openAIResponse("\(providerName) response did not contain message content.")
        }
        return content
    }

    private func decodeSummary(from text: String) throws -> SummaryResult {
        try SummaryJSONDecoder.decode(from: text)
    }
}
