import AppKit
import FinderSync
import OSLog
import Security

/// Requests from Finder's "Convert to ▸" menu (the Finder Menu extension). The extension sends a link,
/// convertanything://convert?to=docx&file=/path&file=/path (or to=combine), which also starts the app.
///
/// Any app or web page can open a link, and a conversion moves or deletes the original, so a link is only
/// acted on when the process that sent it is this app's own extension, checked by its code signature.
enum FinderMenuRequests {
    struct Request {
        let files: [URL]
        let choice: MenuPlan.Choice
    }

    /// Set by AppModel. Requests that arrive before it's set (the link that started the app) wait for it.
    static var handler: ((Request) -> Void)? {
        didSet {
            guard let handler else { return }
            let waiting = pending
            pending = []
            waiting.forEach(handler)
        }
    }
    private static var pending: [Request] = []
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ConvertAnything", category: "finder-menu")

    /// From `applicationWillFinishLaunching`, so a link that started the app isn't missed.
    static func install() {
        NSAppleEventManager.shared().setEventHandler(
            Receiver.shared, andSelector: #selector(Receiver.handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Whether Finder shows the menu. It's off until it's turned on in System Settings.
    static var isEnabled: Bool { FIFinderSyncController.isExtensionEnabled }

    /// System Settings' list of Finder extensions, where the menu is turned on.
    static func openSettings() { FIFinderSyncController.showExtensionManagementInterface() }

    fileprivate static func received(_ event: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let link = URLComponents(string: text), link.scheme == "convertanything", link.host == "convert" else { return }
        guard sentByOwnExtension(event) else {
            let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? -1
            log.error("Ignored a convert link that didn't come from the Finder menu (sender pid \(pid))")
            return
        }
        let items = link.queryItems ?? []
        let files = items.filter { $0.name == "file" }.compactMap(\.value).map { URL(fileURLWithPath: $0) }
        guard let choice = items.first(where: { $0.name == "to" })?.value.flatMap(MenuPlan.Choice.init(value:)), !files.isEmpty else {
            log.error("Ignored a convert link without files or a format")
            return
        }
        let request = Request(files: files, choice: choice)
        if let handler { handler(request) } else { pending.append(request) }
    }

    /// The sender is identified by its audit token (unlike a process ID, it can't be reused by another
    /// process), and must be validly signed code at this app's own PlugIns/Finder Menu.appex.
    private static func sentByOwnExtension(_ event: NSAppleEventDescriptor) -> Bool {
        let attributes: [CFString: Any]
        if let token = event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data, !token.isEmpty {
            attributes = [kSecGuestAttributeAudit: token]
        } else if let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 {
            attributes = [kSecGuestAttributePid: pid]
        } else {
            return false
        }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        var path: CFURL?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path = path as URL? else { return false }
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return false }
        let expected = plugIns.appending(path: "Finder Menu.appex").resolvingSymlinksInPath().standardizedFileURL.path
        return path.resolvingSymlinksInPath().standardizedFileURL.path == expected
    }

    final class Receiver: NSObject {
        static let shared = Receiver()
        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            FinderMenuRequests.received(event)
        }
    }
}
