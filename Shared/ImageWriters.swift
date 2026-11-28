import ImageIO
import UniformTypeIdentifiers

/// What ImageIO can write on this Mac. JPEG XL and TGA support depends on the macOS version, so they're only
/// offered as conversion targets when they're on the list. Asked once, the first time anyone needs it.
nonisolated enum ImageWriters {
    private static let identifiers = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    static func supports(_ format: Format) -> Bool {
        guard let type = format.utType else { return false }
        return identifiers.contains(type.identifier)
    }
}

nonisolated extension Format {
    var utType: UTType? {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .ico: .ico
        case .avif: UTType("public.avif")
        case .icns: .icns
        case .tga: UTType("com.truevision.tga-image")
        case .jxl: UTType("public.jpeg-xl")
        case .pdf: .pdf
        default: nil
        }
    }
}
