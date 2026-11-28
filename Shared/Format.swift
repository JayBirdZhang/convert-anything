import Foundation

nonisolated enum Format: String, CaseIterable, Sendable {
    // Images
    case png, jpeg, heic, tiff, gif, bmp, webp, avif, ico
    // More images: camera RAW, Photoshop and SVG are only read; JPEG XL and TGA are written when this macOS can
    case cr2, cr3, nef, arw, dng, raf, orf, rw2, pef, srw, psd, svg, jxl, tga, icns
    // Documents (including presentations)
    case pdf, md, txt, html, docx, doc, rtf, odt, pages, epub, pptx, ppt, key
    // Spreadsheets
    case xlsx, xls, csv, numbers, json
    // Audio
    case mp3, wav, m4a, aac, flac, ogg, opus, aiff
    // Video
    case mp4, mov, m4v
    // Subtitles (written by transcription; read back as plain text)
    case srt, vtt

    enum Kind { case image, document, spreadsheet, audio, video }

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": self = .jpeg
        case "tif", "tiff": self = .tiff
        case "heif", "heic": self = .heic
        case "htm", "html": self = .html
        case "markdown", "md": self = .md
        case "text", "txt": self = .txt
        case "aif", "aiff": self = .aiff
        case "targa": self = .tga
        default:
            guard let format = Format(rawValue: ext.lowercased()) else { return nil }
            self = format
        }
    }

    var kind: Kind {
        switch self {
        case .png, .jpeg, .heic, .tiff, .gif, .bmp, .webp, .avif, .ico,
             .cr2, .cr3, .nef, .arw, .dng, .raf, .orf, .rw2, .pef, .srw, .psd, .svg, .jxl, .tga, .icns: .image
        case .pdf, .md, .txt, .html, .docx, .doc, .rtf, .odt, .pages, .epub, .pptx, .ppt, .key: .document
        case .xlsx, .xls, .csv, .numbers, .json: .spreadsheet
        case .mp3, .wav, .m4a, .aac, .flac, .ogg, .opus, .aiff: .audio
        case .mp4, .mov, .m4v: .video
        case .srt, .vtt: .document
        }
    }

    /// Plain-text formats can't be told apart by their bytes, so for these
    /// we trust the file's old extension instead. (JSON is deliberately not sniffed: a .txt or .md file that
    /// happens to start with "[" must not turn into a JSON source.)
    var isPlainText: Bool { [.md, .txt, .html, .csv, .json].contains(self) }

    /// Camera RAW files. Most share TIFF's first bytes, so their old extension says which one they are.
    var isRaw: Bool { [.cr2, .cr3, .nef, .arw, .dng, .raf, .orf, .rw2, .pef, .srw].contains(self) }

    /// Whether a file can be converted *into* this format. RAW, Photoshop and SVG files are only read.
    /// JPEG XL and TGA depend on what ImageIO can write on this Mac, so they're only offered when it can.
    var isWritable: Bool {
        switch self {
        case .svg, .psd: false
        case .jxl, .tga: ImageWriters.supports(self)
        default: !isRaw
        }
    }

    var isSlides: Bool { [.pptx, .ppt, .key].contains(self) }

    /// Apple's iWork files all look alike inside, so their old extension says which one it is.
    var isIWork: Bool { [.pages, .key, .numbers].contains(self) }

    var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .md: "Markdown"
        case .txt: "plain text"
        case .pptx: "PowerPoint"
        case .psd: "Photoshop"
        case .jxl: "JPEG XL"
        case .tga: "TGA"
        case .ppt: "PowerPoint 97"
        case .key: "Keynote"
        case .pages: "Pages"
        case .epub: "EPUB"
        case .numbers: "Numbers"
        case .xlsx: "Excel"
        case .xls: "Excel 97"
        case .doc: "Word 97"
        case .docx: "Word"
        default: rawValue.uppercased()
        }
    }
}

/// Identifies what a file really contains by reading its first bytes,
/// regardless of what its extension claims.
nonisolated enum Sniffer {
    enum Result: Equatable {
        case format(Format)
        case text      // Valid UTF-8 with no recognizable markup
        case iWork     // A Pages, Numbers or Keynote file
        case unknown
    }

    /// `claimed` is the file's old extension. It settles the formats whose bytes aren't distinctive: most camera
    /// RAW files start like TIFF, and a TGA file has no signature at all.
    static func detect(_ url: URL, claimed: Format? = nil) -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard !data.isEmpty else { return .unknown }
        let b = [UInt8](data)

        func at(_ offset: Int, _ ascii: String) -> Bool {
            let bytes = Array(ascii.utf8)
            return b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
        }

        if claimed == .tga, looksLikeTGA(b) { return .format(.tga) }   // Before ICO: an indexed TGA starts 00 00 01 00 too
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .format(.png) }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .format(.jpeg) }
        if at(0, "GIF8") { return .format(.gif) }
        if at(0, "BM") && b.count > 14 { return .format(.bmp) }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) {
            if b.count > 10 && b[8] == 0x43 && b[9] == 0x52 { return .format(.cr2) }   // "CR" after the first directory offset
            if let claimed, claimed.isRaw { return .format(claimed) }
            return .format(.tiff)
        }
        if b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .format(claimed?.isRaw == true ? claimed! : .tiff) }
        // Olympus and Panasonic RAW use TIFF's byte order mark with their own version number.
        if b.starts(with: [0x49, 0x49, 0x52, 0x4F]) || b.starts(with: [0x49, 0x49, 0x52, 0x53]) || b.starts(with: [0x4D, 0x4D, 0x4F, 0x52]) { return .format(.orf) }
        if b.starts(with: [0x49, 0x49, 0x55, 0x00]) { return .format(.rw2) }
        if at(0, "FUJIFILMCCD-RAW") { return .format(.raf) }
        if at(0, "8BPS") { return .format(.psd) }
        if at(0, "icns") { return .format(.icns) }
        if b.starts(with: [0xFF, 0x0A]) || b.starts(with: [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]) { return .format(.jxl) }
        if b.starts(with: [0x00, 0x00, 0x01, 0x00]) { return .format(.ico) }
        if at(0, "%PDF") { return .format(.pdf) }
        if at(0, "{\\rtf") { return .format(.rtf) }
        if b.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return detectLegacyOffice(url) }
        if at(0, "fLaC") { return .format(.flac) }
        if at(0, "FORM") && (at(8, "AIFF") || at(8, "AIFC")) { return .format(.aiff) }
        if at(0, "RIFF") {
            if at(8, "WEBP") { return .format(.webp) }
            if at(8, "WAVE") { return .format(.wav) }
        }
        if at(0, "OggS") { return .format(data.range(of: Data("OpusHead".utf8)) != nil ? .opus : .ogg) }
        if at(4, "ftyp") && b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            switch brand {
            case "qt  ": return .format(.mov)
            case "M4A ", "M4B ": return .format(.m4a)
            case "M4V ", "M4VH", "M4VP": return .format(.m4v)
            case "heic", "heix", "heim", "heis", "mif1", "msf1": return .format(.heic)
            case "avif", "avis": return .format(.avif)
            case "crx ": return .format(.cr3)
            default: return .format(.mp4)
            }
        }
        if at(0, "ID3") { return .format(.mp3) }
        if b.count > 1 && b[0] == 0xFF {
            if b[1] & 0xF6 == 0xF0 { return .format(.aac) }   // ADTS
            if b[1] & 0xE0 == 0xE0 { return .format(.mp3) }   // MPEG audio frame sync
        }
        if at(0, "PK\u{03}\u{04}") { return detectZip(url, head: data) }
        if let subtitles = detectSubtitles(data) { return .format(subtitles) }

        // Text: no NUL bytes and valid UTF-8 (allowing a character cut off at the 4 KB boundary).
        if !b.contains(0), String(data: data, encoding: .utf8) != nil || String(data: data.dropLast(3), encoding: .utf8) != nil {
            let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return .format(.html) }
            // SVG is text too. A file that starts with <svg is one; one that starts with an XML header or a comment
            // could just as well be an HTML or Markdown page with an inline icon, so its extension has to say so.
            if head.hasPrefix("<svg") && claimed?.isPlainText != true { return .format(.svg) }
            if claimed == .svg && (head.hasPrefix("<?xml") || head.hasPrefix("<!") ) && data.range(of: Data("<svg".utf8)) != nil { return .format(.svg) }
            return .text
        }
        return .unknown
    }

    /// A TGA header: colour map type 0 or 1, a known image type (indexed, true-colour, grey; plain or run-length),
    /// and a pixel depth TGA actually uses.
    private static func looksLikeTGA(_ b: [UInt8]) -> Bool {
        guard b.count >= 18, b[1] <= 1, [1, 2, 3, 9, 10, 11].contains(b[2]), [8, 15, 16, 24, 32].contains(b[16]) else { return false }
        return b[12] | b[13] != 0 && b[14] | b[15] != 0   // Width and height aren't zero
    }

    /// Whether a text file's first character is `{` or `[`. Used only to recognize JSON that was saved with a
    /// different extension, never to decide a file's format on its own.
    static func looksLikeJSON(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64)) ?? Data()
        let first = head.drop { [0x20, 0x09, 0x0A, 0x0D].contains($0) }.first ?? 0
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    /// Subtitles are text, but their cue timings give them away, so a .txt full of cues renamed to .srt
    /// is just an extension fix.
    private static func detectSubtitles(_ data: Data) -> Format? {
        var head = String(decoding: data.prefix(256), as: UTF8.self)
        if head.hasPrefix("\u{FEFF}") { head.removeFirst() }
        if head.hasPrefix("WEBVTT") { return .vtt }
        let lines = head.split(whereSeparator: \.isNewline).prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, Int(lines[0]) != nil else { return nil }
        return lines[1].wholeMatch(of: /\d+:\d\d:\d\d,\d{3} *--> *\d+:\d\d:\d\d,\d{3}.*/) != nil ? .srt : nil
    }

    /// Old Word, Excel and PowerPoint files share one container format; the name of the main stream
    /// inside (stored as UTF-16) says which one it is.
    private static func detectLegacyOffice(_ url: URL) -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 2_000_000) else { return .unknown }
        try? handle.close()
        func has(_ name: String) -> Bool { data.range(of: name.data(using: .utf16LittleEndian)!) != nil }
        if has("WordDocument") { return .format(.doc) }
        if has("Workbook") || has("Book") { return .format(.xls) }
        if has("PowerPoint Document") { return .format(.ppt) }
        return .unknown
    }

    /// docx, pptx, xlsx, odt and epub are all zip archives. odt and epub name themselves in the first entry
    /// (epub's is a stored file called "mimetype", so its text sits at a fixed spot near the start);
    /// Office files are told apart by the folder names listed in the zip's directory at the end of the file.
    private static func detectZip(_ url: URL, head: Data) -> Result {
        if head.range(of: Data("application/vnd.oasis.opendocument.text".utf8)) != nil { return .format(.odt) }
        if head.dropFirst(30).starts(with: Data("mimetype".utf8)), head.prefix(100).range(of: Data("application/epub+zip".utf8)) != nil { return .format(.epub) }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        if tail.range(of: Data("ppt/presentation.xml".utf8)) != nil { return .format(.pptx) }
        if tail.range(of: Data("word/document.xml".utf8)) != nil { return .format(.docx) }
        if tail.range(of: Data("xl/workbook.xml".utf8)) != nil { return .format(.xlsx) }
        if tail.range(of: Data("Index/Document.iwa".utf8)) != nil { return .iWork }
        return .unknown
    }
}
