import AppKit
import OSLog

/// SPIKE: receives convertanything:// links and logs who sent them.
enum FinderMenuRequests {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ConvertAnything", category: "finder-menu")

    static func install() {
        NSAppleEventManager.shared().setEventHandler(
            Handler.shared, andSelector: #selector(Handler.handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    final class Handler: NSObject {
        static let shared = Handler()
        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            let link = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue ?? "?"
            let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? -1
            let path = NSRunningApplication(processIdentifier: pid)?.executableURL?.path ?? senderPath(pid) ?? "?"
            log.notice("Link \(link, privacy: .public) from pid \(pid) at \(path, privacy: .public)")
        }

        private func senderPath(_ pid: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: 4096)
            return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        }
    }
}
