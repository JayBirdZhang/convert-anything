import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Turns a file of one format into another, choosing the right engine for the pair. Everything runs on
/// macOS's own frameworks, the libraries built into the app (LAME, libwebp), or, for Office and iWork
/// files, Keynote, Numbers and Pages.
extension Converter {
    /// Video, transcription and the iWork apps are slow or can only do one file at a time, so they run one at a time.
    static func isHeavy(from: Format, to: Format) -> Bool {
        switch route(from: from, to: to) {
        case .media: from.kind == .video || to.kind == .video
        case .fromSlides, .slidesExport: true
        case .spreadsheet: !Spreadsheets.runsWithoutNumbers(from: from, to: to)
        case .document: from == .pages || (to == .pdf && [.docx, .doc, .rtf].contains(from))
        case .documentToImage: isHeavy(from: from, to: .pdf)
        case .transcription: true
        default: false
        }
    }

    struct Request: Sendable {
        let input: URL          // A private copy of the file, named input.<source extension>
        let from: Format
        let to: Format
        let workDir: URL
        let title: String       // File name without extension, used for document titles
        let originalDir: URL    // Lets HTML and Markdown find images referenced by relative path
        var allPages = false    // PDF/slides → image: render every page into a folder instead of just the first
        var outputExtension: String?   // The extension as typed (jpg vs jpeg), for naming page images
        var editableSlides = false     // PDF → pptx: editable text boxes instead of page pictures
        var quality: Quality = .balanced
    }

    /// Returns the URL of the converted file inside `request.workDir`, or of a folder when the result is
    /// several files (every page of a PDF as images, every sheet of a workbook as CSV).
    static func convert(_ request: Request, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let route = route(from: request.from, to: request.to) else {
            throw ConversionError.unsupported(request.from, request.to)
        }
        let output = request.workDir.appending(path: "output.\(request.to.rawValue)")
        var result = output
        switch route {
        case .image:
            try await background {
                if request.to == .webp {
                    try WebP.write(imageAt: request.input, to: output, quality: request.quality)
                } else {
                    try ImageConversion.convert(request.input, to: request.to, output: output, quality: request.quality)
                }
            }
        case .imageToPDF:
            try await background {
                try ImageConversion.imageToPDF(request.input, output: output, quality: request.quality)
            }
        case .pdfToImage:
            result = try await renderPages(of: request.input, request: request, output: output, progress: progress)
        case .fromSlides:
            let pdf = request.to == .pdf ? output : request.workDir.appending(path: "slides.pdf")
            // Keynote matches PowerPoint's fonts and layout best. When it isn't installed or fails, Quick Look
            // (built into macOS, rougher but always there) renders the slides so the conversion still finishes.
            do {
                try await IWork.export(request.input, with: .keynote, as: .pdf, to: pdf)
            } catch ConversionError.cancelled {
                throw ConversionError.cancelled
            } catch where request.from != .key {
                try? FileManager.default.removeItem(at: pdf)
                try await QuickLookSlides.renderPDF(request.input, workDir: request.workDir, output: pdf)
            }
            if request.to != .pdf {
                result = try await renderPages(of: pdf, request: request, output: output, progress: progress)
            }
        case .slidesExport:
            try await IWork.export(request.input, with: .keynote, as: .powerPoint, to: output)
        case .toSlides:
            try await SlideBuilder.build(request, output: output, progress: progress)
        case .spreadsheet:
            switch (request.from, request.to) {
            case (.xlsx, .csv):
                result = try await Spreadsheets.xlsxToCSV(request, output: output)
            case (.csv, .xlsx):
                try await Spreadsheets.csvToXLSX(request, output: output)
            case (_, .json):
                result = try await DataFormats.tableToJSON(request, output: output)
            case (.json, .csv), (.json, .xlsx):
                try await DataFormats.jsonToTable(request, output: output)
            default:
                let format: IWork.ExportFormat = request.to == .pdf ? .pdf : request.to == .csv ? .csv : .excel
                // Numbers can't open JSON, so it gets the table as a CSV file.
                let source = request.from == .json ? try await DataFormats.jsonAsCSV(request) : request.input
                result = try await IWork.export(source, with: .numbers, as: format, to: output)
            }
        case .textRecognition:
            try await TextRecognition.convertImage(request, output: output)
        case .document:
            try await DocumentConversion.convert(request, output: output)
        case .media:
            try await MediaConversion.convert(request, output: output, progress: progress)
        case .transcription:
            try await Transcription.convert(request, output: output, progress: progress)
        case .subtitles:
            try await Subtitles.convert(request, output: output)
        case .documentToImage:
            // Same layout as converting to PDF (fonts, page size, margins), so the picture matches that PDF.
            var pdfRequest = Request(input: request.input, from: request.from, to: .pdf, workDir: request.workDir,
                                     title: request.title, originalDir: request.originalDir)
            pdfRequest.quality = request.quality
            let pdf = try await convert(pdfRequest) { _ in }
            result = try await renderPages(of: pdf, request: request, output: output, progress: progress)
        }
        guard FileManager.default.fileExists(atPath: result.path) else {
            throw ConversionError.failed("The converter didn't produce a file.")
        }
        return result
    }

    /// Renders the first page to `output`, or, with `allPages`, every page of a multi-page PDF
    /// into a folder of images named "<title> 01", "<title> 02"…
    private static func renderPages(of pdf: URL, request: Request, output: URL,
                                    progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let folder = request.workDir.appending(path: "pages")
        let typedExtension = request.outputExtension ?? request.to.rawValue

        let allPages = try await background { () throws -> Bool in
            guard let document = PDFDocument(url: pdf), document.pageCount > 0, let first = document.page(at: 0) else {
                throw ConversionError.failed("Couldn't read this PDF.")
            }
            let pageCount = document.pageCount
            // Markdown, text and HTML have no pages of their own, so the last page loses the empty space
            // below its last line instead of keeping the whole letter-size sheet the PDF step laid it out on.
            let trimsLastPage = [.md, .txt, .html, .epub].contains(request.from)
            @Sendable func save(_ page: PDFPage, to url: URL, isLast: Bool) throws {
                var image = try ImageConversion.render(page, scale: request.quality.pageScale)
                if trimsLastPage && isLast { image = ImageConversion.trimmingBottom(of: image) }
                if request.to == .webp {
                    try WebP.write(image, to: url, quality: request.quality)
                } else {
                    try ImageConversion.write(image, to: url, format: request.to,
                                              properties: [kCGImageDestinationLossyCompressionQuality: request.quality.imageQuality])
                }
            }
            guard request.allPages && pageCount > 1 else { try save(first, to: output, isLast: pageCount == 1); return false }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let digits = max(2, String(pageCount).count)
            // Pages are independent, so they render side by side; each lands in its own numbered file.
            _ = try await PageWorkers.map(pdf, pageCount: pageCount, progress: progress) { page, index in
                let name = "\(request.title) \(String(format: "%0\(digits)d", index + 1)).\(typedExtension)"
                try save(page, to: folder.appending(path: name), isLast: index == pageCount - 1)
            }
            return true
        }
        return allPages ? folder : output
    }
}

// MARK: - Parallel pages

/// Runs per-page work for a PDF on several cores. PDFKit documents aren't meant to be shared between threads,
/// so each worker opens its own copy and takes the next unclaimed page. Pages render at ~10 MB each, so the
/// worker count stays small.
nonisolated enum PageWorkers {
    private final class State<Value>: @unchecked Sendable {
        let lock = NSLock()
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Calls `body(page, index)` for every page and returns the results in page order (nil where the page
    /// couldn't be read). `progress` is called with the finished fraction, never going backwards.
    static func map<T: Sendable>(_ url: URL, pageCount: Int, maxWorkers: Int = 8,
                                 progress: (@Sendable (Double) -> Void)? = nil,
                                 _ body: @escaping @Sendable (PDFPage, Int) throws -> T) async throws -> [T?] {
        let state = State((next: 0, done: 0, results: [T?](repeating: nil, count: pageCount)))
        let workers = max(1, min(pageCount, ProcessInfo.processInfo.activeProcessorCount, maxWorkers))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    guard let document = PDFDocument(url: url) else { throw ConversionError.failed("Couldn't read this PDF.") }
                    while true {
                        try Task.checkCancellation()
                        let index = state.lock.withLock { () -> Int in state.value.next += 1; return state.value.next - 1 }
                        guard index < pageCount else { return }
                        guard let page = document.page(at: index) else { continue }
                        let result = try body(page, index)
                        state.lock.withLock {
                            state.value.results[index] = result
                            state.value.done += 1
                            progress?(Double(state.value.done) / Double(pageCount))
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        return state.value.results
    }
}

// MARK: - Quality

/// How much to favor quality over file size. Applies to photos, page images, audio and video;
/// documents and lossless formats aren't affected.
nonisolated enum Quality: String, CaseIterable, Sendable {
    case best, balanced, small

    var title: String {
        switch self {
        case .best: "Best quality"
        case .balanced: "Balanced"
        case .small: "Smaller files"
        }
    }

    var imageQuality: Double { switch self { case .best: 0.95; case .balanced: 0.88; case .small: 0.7 } }
    var webpQuality: Int { switch self { case .best: 92; case .balanced: 84; case .small: 70 } }
    /// Photos are scaled down so their longest side is at most this many pixels.
    var maxImageSide: Int? { self == .small ? 2560 : nil }
    /// PDF and slide pages: 2.5x = 180 dpi, 2x = 144 dpi, 1.5x = 108 dpi.
    var pageScale: CGFloat { switch self { case .best: 2.5; case .balanced: 2; case .small: 1.5 } }

    /// GIF frame rate, longest side in pixels ("Best" keeps the video's own size up to 1920), and how much a
    /// pixel's color may change (|Δr|+|Δg|+|Δb|) before it's redrawn, so video noise doesn't cost file size.
    var gifSettings: (fps: Int, width: Int, noise: Int) {
        switch self {
        case .best: (20, 1920, 6)
        case .balanced: (15, 1080, 7)
        case .small: (10, 540, 12)
        }
    }

    var mp3VBR: Int { switch self { case .best: 0; case .balanced: 2; case .small: 5 } }
    var aacBitrate: Int { switch self { case .best: 256_000; case .balanced: 192_000; case .small: 128_000 } }
}

// MARK: - Images

nonisolated enum ImageConversion {
    /// Reads an image with its EXIF rotation applied, scaled down for "Smaller files".
    static func load(_ input: URL, quality: Quality, maxSide: Int? = nil) throws -> CGImage {
        try decode(input, quality: quality, maxSide: maxSide).image
    }

    static func convert(_ input: URL, to format: Format, output: URL, quality: Quality = .balanced) throws {
        // macOS's GIF writer keeps only the first frame and has no dithering; ours keeps animations.
        if format == .gif { return try GIFEncoder.write(imageAt: input, to: output, quality: quality) }
        var (image, properties) = try decode(input, quality: quality, maxSide: format == .ico ? 256 : format == .icns ? 1024 : nil)
        // A RAW photo decodes at 16 bits; as PNG that doubles the time and the size for no visible gain.
        // (TIFF keeps all 16 bits.)
        if format == .png, image.bitsPerComponent > 8, Format(fileExtension: input.pathExtension)?.isRaw == true {
            image = try image.at8BitsPerChannel()
        }
        // An icon has to be square, so a wider or taller picture is centered on a transparent square.
        if format == .ico, image.width != image.height {
            image = try ICNS.square(image, pixels: max(image.width, image.height))
        }
        if [.jpeg, .bmp].contains(format), image.hasAlpha {
            image = try image.flattenedOnWhite()
        }

        var metadata = properties
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        metadata[kCGImageDestinationLossyCompressionQuality] = quality.imageQuality
        metadata[kCGImagePropertyPixelWidth] = nil
        metadata[kCGImagePropertyPixelHeight] = nil
        try write(image, to: output, format: format, properties: metadata)
    }

    static func isSVG(_ url: URL) -> Bool { url.pathExtension.lowercased() == "svg" }

    private static func decode(_ input: URL, quality: Quality, maxSide: Int?) throws -> (image: CGImage, properties: [CFString: Any]) {
        if isSVG(input) { return (try SVG.render(input, quality: quality, maxSide: maxSide), [:]) }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.failed("Couldn't read this image.")
        }
        // An icon file holds the same picture in several sizes; the biggest is the one worth converting.
        var index = 0
        if CGImageSourceGetCount(source) > 1, CGImageSourceGetType(source) as String? == UTType.icns.identifier {
            var best = 0
            for candidate in 0..<CGImageSourceGetCount(source) {
                let p = CGImageSourceCopyPropertiesAtIndex(source, candidate, nil) as? [CFString: Any]
                let pixels = (p?[kCGImagePropertyPixelWidth] as? Int ?? 0) * (p?[kCGImagePropertyPixelHeight] as? Int ?? 0)
                if pixels > best { best = pixels; index = candidate }
            }
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        var maxSize = max(width, height, 1)
        if let side = quality.maxImageSide { maxSize = min(maxSize, side) }
        if let maxSide { maxSize = min(maxSize, maxSide) }

        // A full-size "thumbnail" with the transform applied bakes in the EXIF rotation (e.g. iPhone photos).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            // The Mac's RAW engine doesn't know every camera (newer or unusual models can be missing).
            throw ConversionError.failed(Format(fileExtension: input.pathExtension)?.isRaw == true
                                         ? "macOS can't read this camera's RAW files." : "Couldn't decode this image.")
        }
        return (image, properties)
    }

    static func write(_ image: CGImage, to output: URL, format: Format, properties: [CFString: Any] = [:]) throws {
        if format == .icns { return try ICNS.write(image, to: output) }
        guard let type = format.utType,
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("Can't write \(format.displayName) images.")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.failed("Couldn't write the \(format.displayName) file.")
        }
    }

    static func imageToPDF(_ input: URL, output: URL, quality: Quality = .balanced) throws {
        if isSVG(input) { return try SVG.writePDF(input, to: output) }
        var picture = Format(fileExtension: input.pathExtension)?.isRaw == true ? try jpegPicture(input, quality: quality) : nil
        picture = picture ?? NSImage(contentsOf: input)
        guard let image = picture, let page = PDFPage(image: image) else {
            throw ConversionError.failed("Couldn't read this image.")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: output) else { throw ConversionError.failed("Couldn't write the PDF.") }
    }

    /// A camera RAW file as a JPEG picture, so a PDF keeps it as a compressed photo instead of
    /// 24 MB of raw pixels (a 36 MP shot), with its rotation applied.
    private static func jpegPicture(_ input: URL, quality: Quality) throws -> NSImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, try load(input, quality: quality),
                                   [kCGImageDestinationLossyCompressionQuality: quality.imageQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? NSImage(data: data as Data) : nil
    }

    /// Renders one page (the first by default) at the quality's resolution.
    static func pdfToImage(_ input: URL, page index: Int = 0, format: Format, output: URL, quality: Quality = .balanced) throws {
        guard let page = PDFDocument(url: input)?.page(at: index) else {
            throw ConversionError.failed("Couldn't read this PDF.")
        }
        try write(render(page, scale: quality.pageScale), to: output, format: format,
                  properties: [kCGImageDestinationLossyCompressionQuality: quality.imageQuality])
    }

    /// Cuts off the blank space below the content, leaving a bottom margin as deep as the top one.
    /// Returns the image unchanged when the page is blank or already full.
    static func trimmingBottom(of image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // Row 0 of the buffer is the top of the image. Near-white counts as blank (anti-aliasing, off-white page fills).
        func hasContent(_ row: Int) -> Bool {
            let start = row * width * 4
            for x in 0..<width {
                let i = start + x * 4
                if pixels[i] < 245 || pixels[i + 1] < 245 || pixels[i + 2] < 245 { return true }
            }
            return false
        }
        guard let top = (0..<height).first(where: hasContent),
              let bottom = (0..<height).reversed().first(where: hasContent) else { return image }
        let newHeight = min(height, bottom + 1 + top)
        guard newHeight < height else { return image }
        return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: newHeight)) ?? image
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) throws -> CGImage {
        // The crop box is the visible page; rotated pages (common in scans) swap width and height.
        let bounds = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.failed("Couldn't render this PDF.")
        }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw ConversionError.failed("Couldn't render this PDF.") }
        return image
    }
}

nonisolated extension CGImage {
    var hasAlpha: Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(alphaInfo)
    }

    /// The same picture and color space with 8 bits per channel.
    fileprivate func at8BitsPerChannel() throws -> CGImage {
        guard let space = colorSpace,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else {
            throw ConversionError.failed("Couldn't process this image.")
        }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ConversionError.failed("Couldn't process this image.") }
        return image
    }

    fileprivate func flattenedOnWhite() throws -> CGImage {
        // Flatten in the image's own RGB space so wide-gamut (Display P3) colors aren't clipped to sRGB.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let own = colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        guard let context = own.flatMap(makeContext) ?? makeContext(sRGB) else {
            throw ConversionError.failed("Couldn't process this image.")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(self, in: rect)
        guard let image = context.makeImage() else { throw ConversionError.failed("Couldn't process this image.") }
        return image
    }
}

