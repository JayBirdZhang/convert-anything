import Foundation

/// What Finder's "Convert to" menu offers for the selected files. It's worked out from file extensions alone:
/// the Finder extension is sandboxed and can't open the files. The app still checks what's really inside each
/// file when it converts, as it does for a rename.
///
/// The shape: the few targets people most likely want, then "Combine into one PDF" when it applies, then
/// everything else grouped by what you get ("More images ▸", "Text from image ▸", "Transcript ▸"…).
struct MenuPlan: Equatable {
    /// What a menu item does.
    nonisolated enum Choice: Hashable {
        case format(Format)
        case combine        // Several images or PDFs into one PDF

        /// How the choice travels in the link to the app and is remembered: a format's raw value, or "combine".
        var value: String {
            switch self {
            case .format(let format): format.rawValue
            case .combine: "combine"
            }
        }

        init?(value: String) {
            if value == "combine" { self = .combine } else if let format = Format(rawValue: value) { self = .format(format) } else { return nil }
        }
    }

    nonisolated enum Entry: Equatable {
        case item(String, Choice)
        case group(String, [(String, Choice)])
        case separator

        static func == (a: Entry, b: Entry) -> Bool {
            switch (a, b) {
            case let (.item(t1, c1), .item(t2, c2)): t1 == t2 && c1 == c2
            case let (.group(t1, i1), .group(t2, i2)): t1 == t2 && i1.map(\.0) == i2.map(\.0) && i1.map(\.1) == i2.map(\.1)
            case (.separator, .separator): true
            default: false
            }
        }
    }

    /// The submenu's rows. Empty means the item is shown greyed out.
    var entries: [Entry] = []
    /// Remembers the last choice for this mix of file types, e.g. "heic" or "jpeg+png".
    var memoryKey = ""

    var isEnabled: Bool { !entries.isEmpty }

    /// How many likely targets come first, counting a remembered choice.
    static let likelyCount = 5

    /// `remembered` is what was chosen last time for the same mix of file types (a `Choice.value`).
    static func make(for urls: [URL], remembered: [String: String] = [:]) -> MenuPlan {
        var plan = MenuPlan()
        var sources: [Format] = []
        for url in urls {
            // Folders (and packages) can't be converted, nor can files we don't know.
            guard !url.hasDirectoryPath, let format = Format(fileExtension: url.pathExtension) else { return plan }
            sources.append(format)
        }
        guard let first = sources.first else { return plan }

        var common = Set(targets(of: first))
        for source in sources.dropFirst() { common.formIntersection(targets(of: source)) }
        let canCombine = sources.count > 1 && sources.allSatisfy { $0.kind == .image || $0 == .pdf }
            && sources.allSatisfy { $0 == .pdf || Converter.route(from: $0, to: .pdf) != nil }
        guard !common.isEmpty || canCombine else { return plan }

        // The likely list of the type most of the files are; on a tie, the first file's.
        let counts = Dictionary(sources.map { ($0, 1) }, uniquingKeysWith: +)
        let main = sources.first { counts[$0] == counts.values.max() } ?? first

        plan.memoryKey = Set(sources.map(\.rawValue)).sorted().joined(separator: "+")
        var last = remembered[plan.memoryKey].flatMap(Choice.init(value:))
        switch last {
        case .format(let format)? where !common.contains(format): last = nil
        case .combine? where !canCombine: last = nil
        default: break
        }

        // Top part: the remembered choice, then the likely ones, filled up by how common formats are.
        var ordered: [Format] = []
        for format in preferred(for: main) + Format.popularity + Format.allCases where common.contains(format) && !ordered.contains(format) {
            ordered.append(format)
        }
        var top: [Choice] = []
        if let last { top.append(last) }
        for format in ordered where top.count < likelyCount && !top.contains(.format(format)) { top.append(.format(format)) }
        if canCombine && !top.contains(.combine) { top.append(.combine) }
        // A name like "Transcript" or "Word (Text from Image)" is only used when it's true of every selected file.
        let distinct = Array(Set(sources))
        func name(_ choice: Choice) -> String {
            let names = Set(distinct.map { title(for: choice, from: $0) })
            return names.count == 1 ? names.first! : plainTitle(choice)
        }
        func groupedName(_ format: Format) -> String {
            let names = Set(distinct.map { itemTitle(format, from: $0) })
            return names.count == 1 ? names.first! : plainTitle(.format(format))
        }
        plan.entries = top.map { .item(name($0), $0) }

        // The rest, grouped by what you get. A group of one is just an item.
        let rest = ordered.filter { !top.contains(.format($0)) }
        var groups: [(title: String?, formats: [Format])] = []
        for format in rest {
            let name = group(from: main, to: format)
            if let name, let index = groups.firstIndex(where: { $0.title == name }) {
                groups[index].formats.append(format)
            } else {
                groups.append((name, [format]))
            }
        }
        // More of the same kind first ("More Images" for a photo), then the rest in order of how common they are.
        let sameKind = groups.filter { $0.formats.first?.kind == main.kind && $0.title?.hasPrefix("More ") == true }
        groups = sameKind + groups.filter { g in !sameKind.contains { $0.title == g.title } }
        if !groups.isEmpty { plan.entries.append(.separator) }
        for group in groups {
            if let name = group.title, group.formats.count > 1 {
                plan.entries.append(.group(name, group.formats.map { (groupedName($0), .format($0)) }))
            } else {
                plan.entries += group.formats.map { .item(name(.format($0)), .format($0)) }
            }
        }
        return plan
    }

    /// Every format a file of this type can become.
    static func targets(of format: Format) -> [Format] {
        Format.allCases.filter { Converter.route(from: format, to: $0) != nil }
    }

    /// Hand-picked "most likely" targets per kind of file, most likely first (chosen for the 1.6 drop-zone
    /// prototype's tiles). Formats a file can't become are skipped.
    static func preferred(for format: Format) -> [Format] {
        if format == .pdf { return [.docx, .png, .jpeg, .txt, .pptx] }
        if format.isSlides { return [.pdf, .png, .jpeg, .pptx] }
        switch format.kind {
        case .image: return [.jpeg, .png, .pdf, .heic, .webp, .gif, .tiff]
        case .video: return [.mp4, .mov, .mp3, .gif, .m4a]
        case .audio: return [.mp3, .m4a, .wav, .txt]
        case .spreadsheet: return [.csv, .xlsx, .pdf, .json]
        case .document: return [.pdf, .md, .txt, .html, .docx]
        }
    }

    /// Which "▸" group a target goes in when it isn't one of the likely ones. Nil: an item of its own.
    static func group(from: Format, to: Format) -> String? {
        switch Converter.route(from: from, to: to) {
        case .textRecognition: return "Text from Image"
        case .transcription: return to == .txt ? nil : "Subtitles"
        case .pdfToImage, .documentToImage: return "Pages as Images"
        case .fromSlides where to.kind == .image: return "Pages as Images"
        default: break
        }
        if from.kind == .video && to.kind == .audio { return "Audio Only" }
        if from.kind == .video && to.kind == .image { return "Picture" }
        if from.kind == .image && to.kind == .video { return "Video" }
        guard from.kind == to.kind else { return nil }
        switch to.kind {
        case .image: return "More Images"
        case .document: return "More Documents"
        case .spreadsheet: return "More Spreadsheets"
        case .audio: return "More Audio"
        case .video: return "More Video"
        }
    }

    /// A row's name, which says what you get when that's not obvious from the format.
    static func title(for choice: Choice, from: Format) -> String {
        guard case .format(let to) = choice else { return "Combine into One PDF" }
        switch Converter.route(from: from, to: to) {
        case .transcription: return to == .txt ? "Transcript" : "Subtitles (\(to.displayName))"
        case .textRecognition: return "\(itemTitle(to, from: from)) (Text from Image)"
        default: break
        }
        if from.kind == .video && to.kind == .audio { return "\(to.displayName) (Audio Only)" }
        return itemTitle(to, from: from)
    }

    /// A row's name inside a group, where the group's name already says what you get.
    static func itemTitle(_ to: Format, from: Format) -> String {
        if Converter.route(from: from, to: to) == .transcription && to == .txt { return "Transcript" }
        return to == .txt ? "Plain Text" : to.displayName
    }

    /// Just the format's name, for a mix of kinds of files.
    static func plainTitle(_ choice: Choice) -> String {
        guard case .format(let to) = choice else { return "Combine into One PDF" }
        return to == .txt ? "Plain Text" : to.displayName
    }
}

extension Format {
    /// Roughly how common each format is, most useful first. Formats not listed here (new ones) come last,
    /// in the order they're declared.
    nonisolated static let popularity: [Format] = [
        .pdf, .docx, .pptx, .txt, .md, .rtf, .html, .odt, .doc,
        .png, .jpeg, .heic, .webp, .gif, .tiff, .bmp, .avif, .ico,
        .xlsx, .csv,
        .m4a, .mp3, .wav, .flac, .aac, .aiff, .opus, .ogg,
        .mp4, .mov, .m4v,
    ]

    /// The extension people usually type.
    nonisolated var preferredExtension: String { self == .jpeg ? "jpg" : rawValue }
}
