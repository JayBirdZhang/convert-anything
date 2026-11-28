import AppKit
import FinderSync

/// Finder's right-click "Convert to ▸" menu. It only builds the menu: the choice goes to the app as a
/// convertanything:// link, which starts the app if it isn't running, and the app converts the files as if
/// they had been renamed.
///
/// The extension is sandboxed and can't read the files, so the menu is worked out from their extensions
/// (MenuPlan.swift, shared with the app).
final class FinderMenu: FIFinderSync {
    /// The last choice per mix of file types (MenuPlan.memoryKey → MenuPlan.Choice.value), so it comes first next time.
    private static let rememberedKey = "rememberedChoices"
    private let defaults = UserDefaults.standard

    /// What the menu that's showing was made for. Finder copies the menu before showing it, so an item is
    /// matched back to its choice by its tag, an index into `choices`.
    private var files: [URL] = []
    private var memoryKey = ""
    private var choices: [MenuPlan.Choice] = []

    override init() {
        super.init()
        // Everywhere, not just the watched folders: the menu is asked for, so it's never a surprise.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return nil }
        let remembered = defaults.dictionary(forKey: Self.rememberedKey) as? [String: String] ?? [:]
        let plan = MenuPlan.make(for: urls, remembered: remembered)
        files = urls
        memoryKey = plan.memoryKey
        choices = []

        let menu = NSMenu(title: "")
        let top = NSMenuItem(title: "Convert to", action: nil, keyEquivalent: "")
        top.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        guard plan.isEnabled else {
            // Greyed out: this can't be converted (a folder, an unknown kind of file, nothing in common).
            top.isEnabled = false
            menu.addItem(top)
            return menu
        }
        let submenu = NSMenu(title: "Convert to")
        for entry in plan.entries {
            switch entry {
            case .item(let title, let choice):
                submenu.addItem(item(title, choice))
            case .group(let title, let items):
                let group = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let groupMenu = NSMenu(title: title)
                for (title, choice) in items { groupMenu.addItem(item(title, choice)) }
                group.submenu = groupMenu
                submenu.addItem(group)
            case .separator:
                submenu.addItem(.separator())
            }
        }
        top.submenu = submenu
        menu.addItem(top)
        return menu
    }

    private func item(_ title: String, _ choice: MenuPlan.Choice) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.tag = choices.count
        choices.append(choice)
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard choices.indices.contains(sender.tag) else { return }
        let choice = choices[sender.tag]
        let urls = files.isEmpty ? FIFinderSyncController.default().selectedItemURLs() ?? [] : files
        guard !urls.isEmpty else { return }

        var remembered = defaults.dictionary(forKey: Self.rememberedKey) as? [String: String] ?? [:]
        remembered[memoryKey] = choice.value
        defaults.set(remembered, forKey: Self.rememberedKey)

        var link = URLComponents()
        link.scheme = "convertanything"
        link.host = "convert"
        link.queryItems = [URLQueryItem(name: "to", value: choice.value)] + urls.map { URLQueryItem(name: "file", value: $0.path) }
        if let url = link.url { NSWorkspace.shared.open(url) }
    }
}
