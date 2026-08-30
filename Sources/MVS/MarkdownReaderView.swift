import AppKit
import SwiftUI

struct MarkdownDocument: Identifiable {
    let id: String
    let url: URL
    let title: String
    let content: String

    init(url: URL) {
        id = url.standardizedFileURL.path
        self.url = url
        title = url.deletingPathExtension().lastPathComponent
        content = (try? String(contentsOf: url, encoding: .utf8)) ?? "Could not read this document."
    }
}

struct MarkdownContentView: View {
    let content: String

    var body: some View {
        ScrollView {
            Text(renderedMarkdown)
                .font(.system(size: 14))
                .foregroundStyle(MVSTheme.ink)
                .frame(maxWidth: 760, alignment: .leading)
                .textSelection(.enabled)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MVSTheme.surface)
    }

    private var renderedMarkdown: AttributedString {
        (try? AttributedString(
            markdown: contentWithoutFrontMatter,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(contentWithoutFrontMatter)
    }

    private var contentWithoutFrontMatter: String {
        guard content.hasPrefix("---\n"),
              let closing = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
            return content
        }
        return String(content[closing.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MarkdownReaderView: View {
    let document: MarkdownDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MVSEnergyCore(active: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(document.url.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(MVSTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([document.url])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(MVSSecondaryButtonStyle())
                Button("Close") { dismiss() }
                    .buttonStyle(MVSPrimaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .background(MVSTheme.canvas)
            Divider()
            MarkdownContentView(content: document.content)
        }
        .frame(minWidth: 760, minHeight: 640)
    }
}
