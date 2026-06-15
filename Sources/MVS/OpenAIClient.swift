import Foundation

@MainActor
final class OpenAIClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func transcribe(chunks: [URL], diarize: Bool) async throws -> TranscriptResult {
        var fullText: [String] = []
        var segments: [TranscriptSegment] = []

        for (index, chunk) in chunks.enumerated() {
            let result = try await transcribeSingleFile(chunk, diarize: diarize, chunkIndex: index)
            fullText.append(result.text)
            segments.append(contentsOf: result.segments)
        }

        return TranscriptResult(text: fullText.joined(separator: "\n\n"), segments: segments)
    }

    private func transcribeSingleFile(_ audioURL: URL, diarize: Bool, chunkIndex: Int) async throws -> TranscriptResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let model = diarize ? "gpt-4o-transcribe-diarize" : "gpt-4o-transcribe"
        let responseFormat = diarize ? "diarized_json" : "json"
        body.appendMultipartField(name: "model", value: model, boundary: boundary)
        body.appendMultipartField(name: "response_format", value: responseFormat, boundary: boundary)
        if !diarize {
            body.appendMultipartField(
                name: "prompt",
                value: "Preserve the source language, domain terms, names, acronyms, punctuation, and timestamps when possible.",
                boundary: boundary
            )
        }
        body.appendMultipartFile(name: "file", fileURL: audioURL, mimeType: mimeType(for: audioURL), boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let data = try await validatedData(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = object?["text"] as? String else {
            throw MVSError.openAIResponse("Transcription response did not contain text.")
        }

        let rawSegments = object?["segments"] as? [[String: Any]] ?? []
        let segments = rawSegments.enumerated().map { offset, segment in
            TranscriptSegment(
                id: "chunk-\(chunkIndex)-segment-\(offset)",
                start: segment["start"] as? Double,
                end: segment["end"] as? Double,
                speaker: segment["speaker"] as? String,
                text: segment["text"] as? String ?? ""
            )
        }
        return TranscriptResult(text: text, segments: segments)
    }

    private func validatedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MVSError.openAIResponse("Missing HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw MVSError.openAIResponse(message)
        }
        return data
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        default: "application/octet-stream"
        }
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(name: String, fileURL: URL, mimeType: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        if let fileData = try? Data(contentsOf: fileURL) {
            append(fileData)
        }
        append("\r\n".data(using: .utf8)!)
    }
}
