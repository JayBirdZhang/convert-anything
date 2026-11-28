import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - SVG

/// SVG pictures, drawn by AppKit's own SVG support (macOS 14 and later).
nonisolated enum SVG {
    /// The picture's own size in points, from its width and height or its viewBox.
    private static func load(_ url: URL) throws -> (image: NSImage, size: CGSize) {
        guard let image = NSImage(contentsOf: url), image.size.width >= 1, image.size.height >= 1 else {
            throw ConversionError.failed("Couldn't read this SVG.")
        }
        return (image, image.size)
    }

    /// Draws the picture as a bitmap with a transparent background. SVGs are often tiny (a 24 pt icon),
    /// so the long side is at least 1024 pixels, or the quality's page scale for bigger pictures, but
    /// never more than `maxSide` (or 8192).
    static func render(_ url: URL, quality: Quality, maxSide: Int? = nil) throws -> CGImage {
        let (image, size) = try load(url)
        let long = max(size.width, size.height)
        let cap = Double(min(8192, quality.maxImageSide ?? 8192, maxSide ?? 8192))
        let pixels = min(long * max(quality.pageScale, 1024 / long), cap)
        let scale = pixels / long
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))

        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failed("Couldn't render this SVG.")
        }
        draw(image, in: context, rect: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError.failed("Couldn't render this SVG.") }
        return result
    }

    /// A one-page PDF with the SVG's paths and text kept as vectors, so it stays sharp at any zoom.
    static func writePDF(_ url: URL, to output: URL) throws {
        let (image, size) = try load(url)
        let scale = max(1, 512 / max(size.width, size.height))   // Tiny icons get a page big enough to see
        var box = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.failed("Couldn't write the PDF.")
        }
        context.beginPDFPage(nil)
        draw(image, in: context, rect: box)
        context.endPDFPage()
        context.closePDF()
    }

    private static func draw(_ image: NSImage, in context: CGContext, rect: CGRect) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.interpolationQuality = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current = previous
    }
}

// MARK: - ICNS

/// Writes app icons. The file is put together here rather than by ImageIO, which stores a single size:
/// an icon needs every size from 16 to 1024 pixels, including the @2x ones, so it's sharp in the Dock,
/// Finder and Get Info alike.
nonisolated enum ICNS {
    /// The sizes in pixels, and the chunk types each fills. Retina sizes reuse the next size up's picture.
    private static let chunks: [(pixels: Int, types: [String])] = [
        (16, ["icp4"]),
        (32, ["icp5", "ic11"]),          // 32 px, and 16 pt @2x
        (64, ["ic12"]),                  // 32 pt @2x
        (128, ["ic07"]),
        (256, ["ic08", "ic13"]),         // 256 px, and 128 pt @2x
        (512, ["ic09", "ic14"]),         // 512 px, and 256 pt @2x
        (1024, ["ic10"]),                // 512 pt @2x
    ]

    static func write(_ image: CGImage, to output: URL) throws {
        // Icons are square: a wide or tall picture is centered with transparent margins.
        // Each size is made from the next one up, which keeps small sizes crisp instead of aliased.
        var current = try square(image, pixels: 1024)
        var png: [Int: Data] = [1024: try encode(current)]
        for size in [512, 256, 128, 64, 32, 16] {
            current = try square(current, pixels: size)
            png[size] = try encode(current)
        }

        var body = Data()
        for (pixels, types) in chunks {
            let data = png[pixels]!
            for type in types {
                body.append(contentsOf: Array(type.utf8))
                body.append(bigEndian: UInt32(8 + data.count))
                body.append(data)
            }
        }
        var file = Data("icns".utf8)
        file.append(bigEndian: UInt32(8 + body.count))
        file.append(body)
        try file.write(to: output)
    }

    /// The picture centered on a transparent square `pixels` wide.
    static func square(_ image: CGImage, pixels: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failed("Couldn't process this image.")
        }
        context.interpolationQuality = .high
        let scale = Double(pixels) / Double(max(image.width, image.height))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(pixels) - width) / 2, y: (Double(pixels) - height) / 2, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError.failed("Couldn't process this image.") }
        return result
    }

    private static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("Couldn't write the ICNS file.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("Couldn't write the ICNS file.") }
        return data as Data
    }
}

private nonisolated extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
