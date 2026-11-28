import SwiftUI

/// "What can I convert?": every supported conversion, grouped by kind of file. Built from the converter's
/// own routes, so it's always accurate.
struct FormatsView: View {
    let back: () -> Void

    private struct Group: Identifiable {
        let title: String
        let sources: [Format]
        var id: String { title }
    }

    private let groups: [Group] = [
        Group(title: "Images", sources: Format.allCases.filter { $0.kind == .image }),
        Group(title: "Documents", sources: Format.allCases.filter { $0.kind == .document && !$0.isSlides }),
        Group(title: "Presentations", sources: Format.allCases.filter(\.isSlides)),
        Group(title: "Spreadsheets", sources: Format.allCases.filter { $0.kind == .spreadsheet }),
        Group(title: "Audio", sources: Format.allCases.filter { $0.kind == .audio }),
        Group(title: "Video", sources: Format.allCases.filter { $0.kind == .video }),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "What can I convert?", back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        Card(title: group.title) {
                            row("From", group.sources)
                            CardDivider()
                            row("To", targets(of: group.sources))
                        }
                    }
                    Card(title: "Tips") {
                        tip("Rename a photo or scanned PDF to .txt or .docx to get its text")
                        CardDivider()
                        tip("Camera RAW photos, Photoshop files and SVG drawings can be converted, but not created")
                        CardDivider()
                        tip("Rename a recording to .txt, or a video to .srt, for a transcript made on your Mac")
                        CardDivider()
                        tip("Rename a file back to undo, or press ⌘Z in Finder")
                        CardDivider()
                        tip("To convert many files, select them, choose Rename… from the right-click menu and replace the extension")
                        CardDivider()
                        tip("PowerPoint, Excel and iWork files use Keynote, Numbers or Pages, free from Apple")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 460)
        }
    }

    private func row(_ label: String, _ formats: [Format]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            FlowLayout(spacing: 4) {
                ForEach(formats, id: \.self) { ExtensionTag($0.preferredExtension, emphasized: label == "To") }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.top] + 12 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): " + formats.map { $0.preferredExtension }.joined(separator: ", "))
    }

    private func tip(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    /// Every format at least one of `sources` can become.
    private func targets(of sources: [Format]) -> [Format] {
        Format.allCases.filter { target in sources.contains { Converter.route(from: $0, to: target) != nil } }
    }
}


/// Lays its views out left to right, wrapping onto new lines like words in a paragraph.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in zip(row.indices, row.xs) {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var indices: [Int] = []; var xs: [CGFloat] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            let x = current.indices.isEmpty ? 0 : current.width + spacing
            current.indices.append(index)
            current.xs.append(x)
            current.width = x + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
