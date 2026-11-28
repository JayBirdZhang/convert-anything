import Foundation

/// Which conversions exist. The app's engines (Converter.swift) and the Finder menu extension both read
/// this, so the menu never offers a pair the app can't make.
enum Converter {
    enum Route {
        case image          // ImageIO (+ libwebp for WebP)
        case imageToPDF     // PDFKit
        case pdfToImage     // PDFKit
        case document       // AppKit's text system, Markdown, Pages for Word → PDF
        case media          // AVFoundation, Core Audio, LAME
        case fromSlides     // Keynote (or Quick Look) renders a presentation as PDF (then pages → images)
        case slidesExport   // Keynote saves older PowerPoint and Keynote files as .pptx
        case toSlides       // One slide per PDF page or image
        case spreadsheet    // Excel ↔ CSV and JSON ↔ CSV/Excel directly; Numbers for the rest
        case textRecognition   // Vision reads the text in an image
        case documentToImage   // A document or spreadsheet is laid out as a PDF, then its pages become images
        case transcription     // Speech framework writes down what's said in audio or video, on the Mac
        case subtitles         // Subtitles lose their timings (→ text and documents) or change format (SRT ↔ WebVTT)
    }

    /// What subtitles become directly; other documents (Word, PDF…) are laid out from their plain text.
    nonisolated static let subtitleTargets: [Format] = [.txt, .md, .srt, .vtt]

    nonisolated static let documentSources: [Format] = [.md, .txt, .html, .docx, .doc, .rtf, .odt, .pages, .pdf, .epub]
    nonisolated static let documentTargets: [Format] = [.md, .txt, .html, .docx, .doc, .rtf, .odt, .pdf, .epub]

    static func route(from: Format, to: Format) -> Route? {
        guard from != to, !to.isIWork, to.isWritable else { return nil }   // Pages, Numbers and Keynote, camera RAW, PSD and SVG can be read but not written
        if let route = transcriptionRoute(from: from, to: to) { return route }
        if from.isSlides {
            if to == .pdf || to.kind == .image { return .fromSlides }
            return to == .pptx ? .slidesExport : nil
        }
        if to.isSlides {
            guard to == .pptx else { return nil }
            return from == .pdf || from.kind == .image ? .toSlides : nil
        }
        if from.kind == .spreadsheet || to.kind == .spreadsheet {
            guard from.kind == .spreadsheet else { return nil }
            if to.kind == .image { return .documentToImage }
            // JSON is read as a table: it can become a spreadsheet (or a laid-out document) but not Excel 97 or Numbers.
            let targets: [Format] = from == .json ? [.pdf, .csv, .xlsx] : [.pdf, .csv, .xlsx, .json]
            return targets.contains(to) ? .spreadsheet : nil
        }
        switch (from.kind, to.kind) {
        case (.image, .image): return .image
        case (.image, .document) where to == .pdf: return .imageToPDF
        case (.image, .document) where from != .svg && [.txt, .md, .docx, .html, .rtf, .odt].contains(to): return .textRecognition
        case (.document, .image) where from == .pdf: return .pdfToImage
        case (.document, .image) where documentSources.contains(from): return .documentToImage
        case (.document, .document) where documentSources.contains(from) && documentTargets.contains(to): return .document
        // macOS reads Ogg and Opus audio but can only write Opus inside Apple's own CAF files.
        case (.audio, .audio), (.video, .audio): return [.ogg, .opus].contains(to) ? nil : .media
        case (.video, .video): return .media
        case (.video, .image) where to != .ico && to != .avif: return .media
        case (.image, .video) where from == .gif: return .media
        default: return nil
        }
    }

    /// Speech → text or subtitles, and subtitles → text or the other subtitle format. Nothing else reads or writes subtitles.
    private static func transcriptionRoute(from: Format, to: Format) -> Route? {
        let subtitles: [Format] = [.srt, .vtt]
        if [.audio, .video].contains(from.kind) && (to == .txt || subtitles.contains(to)) { return .transcription }
        if subtitles.contains(from) { return subtitleTargets.contains(to) || documentTargets.contains(to) ? .subtitles : nil }
        return nil
    }
}
