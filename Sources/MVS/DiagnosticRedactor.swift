import Foundation

enum DiagnosticRedactor {
    static func redact(_ text: String) -> String {
        var value = text
        for pattern in [
            #"(?i)\bsk-[A-Za-z0-9_-]{8,}"#,
            #"(?i)Bearer\s+[A-Za-z0-9._~-]+"#,
            #"(?i)(https?|socks5h?)://[^\s/@]+:[^\s/@]+@"#,
            #"(?i)(api[_-]?key|access[_-]?token|signature|x-amz-signature)=([^\s&]+)"#
        ] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(value.suffix(16_384))
    }
}
