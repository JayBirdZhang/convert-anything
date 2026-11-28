import SwiftUI
import UniformTypeIdentifiers

/// Settings, laid out like System Settings: short labels, the controls on the right, details on hover.
struct SettingsView: View {
    @Bindable var model: AppModel
    let back: () -> Void
    @Bindable private var updates = Updates.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings", back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folders
                    conversions
                    Card(title: "General") {
                        SettingRow("Notify when done") {
                            Toggle("Notify when done", isOn: $model.showNotifications)
                        }
                        CardDivider()
                        SettingRow("Open at login") {
                            Toggle("Open at login", isOn: $model.launchAtLogin)
                        }
                        CardDivider()
                        FinderMenuRow()
                    }
                    Card(title: "Updates") {
                        SettingRow("Check automatically", help: "Look for a new version about once a day and offer to install it.") {
                            Toggle("Check automatically", isOn: $updates.checksAutomatically)
                        }
                        CardDivider()
                        SettingRow("Version \(updates.version)") {
                            Button("Check Now") { updates.checkNow() }
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folders: some View {
        Card(title: "Watched folders") {
            ForEach(model.watchedFolders, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(displayPath(path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    Spacer(minLength: 4)
                    Button {
                        model.removeFolder(path)
                    } label: {
                        Label("Stop Watching", systemImage: "minus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop watching this folder")
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                CardDivider()
            }
            Button {
                model.addFolder()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16, height: 16)
                    Text("Add Folder…")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
        }
    }

    private var conversions: some View {
        Card(title: "Conversions") {
            SettingRow("Originals", help: "Move to Trash keeps a backup you can restore by renaming the file back (or ⌘Z in Finder).") {
                Picker("Originals", selection: $model.originals) {
                    ForEach(OriginalsMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            CardDivider()
            SettingRow("Quality", help: "Smaller files: lower-quality photos (resized to at most 2560 px), audio and video (at most 1080p). Documents aren't affected.") {
                Picker("Quality", selection: $model.quality) {
                    ForEach(Quality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            CardDivider()
            SettingRow("PDF to PowerPoint", help: "Editable text: text you can change, laid over the page's images and shapes. Page pictures: each page as an exact, non-editable image.") {
                Picker("PDF to PowerPoint", selection: $model.editableSlides) {
                    Text("Editable text").tag(true)
                    Text("Page pictures").tag(false)
                }
            }
            CardDivider()
            SettingRow("Export every page", detail: "PDFs and slides renamed to an image",
                       help: "When a multi-page PDF or presentation is renamed to an image format, save every page as an image in a folder. Off: only the first page.") {
                Toggle("Export every page", isOn: $model.exportAllPages)
            }
            CardDivider()
            SettingRow("Combine PDFs", detail: "Files renamed to .pdf together",
                       help: "When several files are renamed to .pdf at once, merge them into a single Combined.pdf in name order.") {
                Toggle("Combine PDFs", isOn: $model.combinePDFs)
            }
        }
    }
}

/// Whether Finder's right-click "Convert to" menu is on. It's turned on in System Settings, which can't tell
/// the app when it changes, so this looks again whenever the app becomes active.
private struct FinderMenuRow: View {
    @State private var isEnabled = FinderMenuRequests.isEnabled

    var body: some View {
        SettingRow("Finder menu", detail: isEnabled ? "Right-click a file, then Convert to" : "Off. Turn it on in System Settings.",
                   help: "Adds Convert to to the menu you get when you right-click files in Finder, as another way to convert them. It's turned on under Login Items & Extensions in System Settings.") {
            Button(isEnabled ? "Settings…" : "Turn On…") { FinderMenuRequests.openSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isEnabled = FinderMenuRequests.isEnabled
        }
        .onAppear { isEnabled = FinderMenuRequests.isEnabled }
    }
}

/// A label (and optional second line) on the left, its control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var help: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .help(help ?? "")
    }
}

/// The hairline between rows of a card, inset like System Settings.
struct CardDivider: View {
    var body: some View { Divider().padding(.leading, 12) }
}
