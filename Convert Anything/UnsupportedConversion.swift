import Foundation

/// Words for the "can't convert that" cases, with a hint at what would work instead.
///
/// The hints come from asking `Converter.route` about every format, so they stay right when formats are
/// added and there's no list to keep in step. It only runs when something has just failed.
enum UnsupportedConversion {
    /// The most the hint names. More than this is a list nobody reads.
    private static let limit = 4

    /// "Can't turn MP3 into OGG. Try M4A, WAV, FLAC or AAC."
    ///
    /// `originalExtension` is what the file was called before the rename. When the file's contents turn out
    /// to be something else (a PNG named .jpg), the message says so, because that's likely the confusion.
    static func message(from: Format, to: Format, originalExtension: String? = nil) -> String {
        let hint = tryList(suggestions(from: from, to: to))
        let reason: String
        if to.isIWork {
            reason = "Can't make \(to.displayName) files, only read them."
        } else if let old = originalExtension.flatMap(Format.init(fileExtension:)), old != from {
            reason = "This is really \(fileNoun(from)), not \(fileNoun(old)), and it can't become \(to.displayName)."
        } else {
            reason = "Can't turn \(name(from)) into \(to.displayName)."
        }
        return hint.isEmpty ? reason : reason + " " + hint
    }

    /// For a rename to an extension the app has never heard of: "Convert Anything doesn't know .xyz. Try …"
    static func unknownExtension(_ ext: String, from: Format) -> String {
        let hint = tryList(suggestions(from: from, to: nil))
        let reason = "Convert Anything doesn't know .\(ext)."
        return hint.isEmpty ? reason : reason + " " + hint
    }

    /// What the file could become, best first: formats of the kind it was renamed to, then of its own kind
    /// (a mistyped image → audio rename most likely wanted another image), then everything else.
    /// Whole kinds that wouldn't fit are boiled down to one example, such as "an image like PNG".
    static func suggestions(from: Format, to: Format?) -> [String] {
        let candidates = ranked(from: from)
        var kinds: [Format.Kind] = []
        for kind in [to?.kind, from.kind].compactMap({ $0 }) + candidates.map(\.kind) where !kinds.contains(kind) {
            kinds.append(kind)
        }

        var items: [String] = []
        for kind in kinds {
            let members = candidates.filter { $0.kind == kind }
            let room = limit - items.count
            guard !members.isEmpty, room > 0 else { continue }
            if items.isEmpty || members.count <= room {
                items += members.prefix(room).map(\.displayName)
            } else {
                items.append("\(noun(kind)) like \(members[0].displayName)")
            }
        }
        return items
    }

    /// Every format the file can be converted to, most common first.
    private static func ranked(from: Format) -> [Format] {
        let all = Array(Format.allCases)
        return all.enumerated()
            .filter { Converter.route(from: from, to: $0.element) != nil }
            .sorted { a, b in
                let ra = Format.popularity.firstIndex(of: a.element) ?? Format.popularity.count
                let rb = Format.popularity.firstIndex(of: b.element) ?? Format.popularity.count
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    private static func tryList(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: "Try \(items[0])."
        default: "Try \(items.dropLast().joined(separator: ", ")) or \(items[items.count - 1])."
        }
    }

    /// "MP3", "a Keynote file": formats named by their letters read fine alone, product names need "file".
    private static func name(_ format: Format) -> String {
        format.displayName == format.rawValue.uppercased() ? format.displayName : fileNoun(format)
    }

    /// "a PNG file", "an Excel file"
    private static func fileNoun(_ format: Format) -> String {
        let name = format.displayName
        return "\(name.first.map { "aeiou".contains($0.lowercased()) } == true ? "an" : "a") \(name) file"
    }

    private static func noun(_ kind: Format.Kind) -> String {
        switch kind {
        case .image: "an image"
        case .document: "a document"
        case .spreadsheet: "a spreadsheet"
        case .audio: "an audio file"
        case .video: "a video"
        }
    }
}
