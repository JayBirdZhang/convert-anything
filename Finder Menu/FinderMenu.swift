import AppKit
import FinderSync
import OSLog

/// SPIKE: the smallest Finder menu that answers whether an ad-hoc-signed extension loads, whether submenu
/// clicks arrive, whether a greyed item stays greyed, and whether a link reaches the app.
final class FinderMenu: FIFinderSync {
    private let log = Logger(subsystem: "io.github.jaybirdzhang.ConvertAnything.FinderMenu", category: "spike")

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        log.notice("Finder menu extension started")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        log.notice("Menu for \(urls.count) item(s)")
        let menu = NSMenu(title: "")
        let top = NSMenuItem(title: "Convert to", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Convert to")
        for (tag, title) in ["JPEG", "PDF", "PNG"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
            sub.addItem(item)
        }
        let more = NSMenuItem(title: "More images", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu(title: "More images")
        let tiff = NSMenuItem(title: "TIFF", action: #selector(choose(_:)), keyEquivalent: "")
        tiff.tag = 10
        tiff.target = self
        moreMenu.addItem(tiff)
        more.submenu = moreMenu
        sub.addItem(.separator())
        sub.addItem(more)
        top.submenu = sub
        menu.addItem(top)

        let greyed = NSMenuItem(title: "Convert to (greyed)", action: nil, keyEquivalent: "")
        greyed.isEnabled = false
        menu.addItem(greyed)
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        log.notice("Chose tag \(sender.tag) title \(sender.title, privacy: .public) for \(urls.count) item(s)")
        var components = URLComponents()
        components.scheme = "convertanything"
        components.host = "convert"
        components.queryItems = [URLQueryItem(name: "to", value: "tag\(sender.tag)")] + urls.map { URLQueryItem(name: "file", value: $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
