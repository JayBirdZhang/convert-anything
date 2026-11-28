import SwiftUI
import AppKit

/// Launch-time hooks: the welcome panel on the very first launch, and again whenever the app is opened
/// while it's already running (a menu-bar app otherwise shows nothing at all when you open it).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        FinderMenuRequests.install()   // Before launch finishes, so a link that started the app isn't missed
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Updates.shared   // Starts Sparkle's daily check
        // Give the menu-bar icon a moment to appear, so the panel can point at it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            WelcomePanel.showOnFirstLaunch()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WelcomePanel.shared.show()
        return false
    }
}

/// A small callout that hangs from the menu-bar icon and says the app is running and how to use it.
final class WelcomePanel {
    static let shared = WelcomePanel()

    private static let shownKey = "shownWelcome"
    private static let width: CGFloat = 330
    private static let tail: CGFloat = 11

    private var panel: NSPanel?
    private var keyObserver: NSObjectProtocol?

    static func showOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)
        shared.show()
    }

    func show() {
        close(animated: false)

        let icon = Self.statusItemFrame()
        guard let screen = icon.flatMap({ Self.screen(containing: $0) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        // Where the panel goes: hanging from the icon when we can see it, else top centre of the screen.
        let x: CGFloat
        var arrowX: CGFloat?
        if let icon {
            x = min(max(icon.midX - Self.width / 2, visible.minX + 8), visible.maxX - Self.width - 8)
            arrowX = icon.midX - x
        } else {
            x = visible.midX - Self.width / 2
        }

        let content = WelcomeView(arrowX: arrowX, tail: arrowX == nil ? 0 : Self.tail,
                                  folders: Self.watchedFolderNames()) { [weak self] in self?.close(animated: true) }
            .frame(width: Self.width)
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        // Frosted background shaped like a callout, matching the menu-bar panel.
        let background = NSVisualEffectView(frame: hosting.frame)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.calloutMask(size: size, arrowX: arrowX)
        background.addSubview(hosting)

        let top = (icon?.minY ?? visible.maxY) - 4
        let finalFrame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)

        let panel = KeyablePanel(contentRect: finalFrame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = background
        panel.onCancel = { [weak self] in self?.close(animated: true) }
        self.panel = panel

        // Slide down out of the icon and fade in, then nod twice toward it.
        panel.alphaValue = 0
        panel.setFrame(finalFrame.offsetBy(dx: 0, dy: 14), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated { panel.map { Self.nod($0, frame: finalFrame, times: 2) } }
        })

        // Opening the real menu (or any other window of ours) means they found it.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let window = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, window != ObjectIdentifier(panel) else { return }
                self.close(animated: true)
            }
        }
    }

    func close(animated: Bool) {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private static func nod(_ panel: NSPanel, frame: NSRect, times: Int) {
        guard times > 0, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame.offsetBy(dx: 0, dy: 6), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().setFrame(frame, display: true)
                }, completionHandler: {
                    MainActor.assumeIsolated { nod(panel, frame: frame, times: times - 1) }
                })
            }
        })
    }

    /// The menu-bar icon's frame on screen, or nil if it isn't showing (a full menu bar or the camera notch can hide it).
    private static func statusItemFrame() -> NSRect? {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            let frame = window.frame
            guard frame.width > 0, window.occlusionState.contains(.visible), screen(containing: frame) != nil else { continue }
            return frame
        }
        return nil
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
    }

    /// Same defaults as AppModel: Desktop, Documents and Downloads until changed in Settings.
    private static func watchedFolderNames() -> [String] {
        let paths = UserDefaults.standard.stringArray(forKey: "watchedFolders") ?? ["Desktop", "Documents", "Downloads"]
        return paths.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// A rounded rectangle with a little pointer on top at `arrowX`.
    private static func calloutMask(size: NSSize, arrowX: CGFloat?) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            let bodyHeight = size.height - (arrowX == nil ? 0 : tail)
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size.width, height: bodyHeight), xRadius: 14, yRadius: 14).fill()
            if let arrowX {
                let pointer = NSBezierPath()
                pointer.move(to: NSPoint(x: arrowX - tail - 1, y: bodyHeight - 0.5))
                pointer.line(to: NSPoint(x: arrowX, y: size.height))
                pointer.line(to: NSPoint(x: arrowX + tail + 1, y: bodyHeight - 0.5))
                pointer.close()
                pointer.fill()
            }
            return true
        }
    }
}

/// Borderless panels can't take key status by default; this one does, so Return and Esc work.
private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct WelcomeView: View {
    let arrowX: CGFloat?
    let tail: CGFloat
    let folders: [String]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Convert Anything is running").font(.headline)
                    Text(arrowX == nil
                         ? "It lives in the menu bar at the top of your screen. If the menu bar is full, its icon may be hidden behind others or the camera."
                         : "It lives up here in the menu bar. Click its icon anytime to see recent conversions or change settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("To convert a file, just rename it:").font(.callout).fontWeight(.medium)
                HStack(spacing: 6) {
                    Text("photo.heic").monospaced()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text("photo.jpg").monospaced()
                }
                .font(.callout)
                Text(folders.isEmpty
                     ? "Choose folders to watch in Settings."
                     : "Works in \(ListFormatter.localizedString(byJoining: folders)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Got It", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .padding(.top, tail)
    }
}
