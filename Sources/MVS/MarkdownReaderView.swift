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
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let marker = block.marker { Text(marker).foregroundStyle(MVSTheme.muted) }
                        Text(block.text)
                            .font(block.font)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, block.indent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
                .foregroundStyle(MVSTheme.ink)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MVSTheme.surface)
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }

    private var blocks: [MarkdownBlock] {
        let source = NoteFrontMatter(content).body
        guard let parsed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) else { return [MarkdownBlock(text: AttributedString(source))] }
        return parsed.runs[\.presentationIntent].map { intent, range in
            var block = MarkdownBlock(text: AttributedString(parsed[range]))
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    block.font = .system(size: level == 1 ? 22 : (level == 2 ? 18 : 15), weight: .semibold)
                case .codeBlock:
                    block.font = .system(size: 12, design: .monospaced)
                case .listItem(let ordinal):
                    block.marker = intent?.components.contains(where: { $0.kind == .orderedList }) == true ? "\(ordinal)." : "•"
                    block.indent = 8
                default: break
                }
            }
            return block
        }
    }
}

private struct MarkdownBlock {
    var text: AttributedString
    var font: Font = .system(size: 14)
    var marker: String?
    var indent: CGFloat = 0
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
