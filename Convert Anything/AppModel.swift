import AppKit
import Observation
import OSLog
import PDFKit
import ServiceManagement
import UserNotifications

@Observable final class Job: Identifiable {
    enum State: Equatable {
        case waiting
        case converting(progress: Double?)
        case done
        case failed(String)
        case cancelled
        case undone
    }

    let id = UUID()
    let originalURL: URL    // Where the file was before the rename, e.g. notes.md
    let fileURL: URL        // The renamed file, which ends up holding the converted result, e.g. notes.docx
    let from: Format
    let to: Format
    let started = Date()
    var state: State = .waiting
    var originalInTrash: URL?
    var keptOriginal: URL?  // With "Keep both", where the original was put back
    var resultURL: URL?     // The converted file, or a folder of images when every page was exported
    var combinedInto: URL?  // When the batch's PDFs were merged, the merged file (the separate ones are in the Trash)
    var resultMissing = false   // Showing it in Finder found it gone
    var pageCount: Int?
    var task: Task<Void, Never>?
    var alreadyPDF = false  // A PDF picked for "Combine into One PDF": nothing to convert, it's merged as it is

    init(originalURL: URL, fileURL: URL, from: Format, to: Format) {
        self.originalURL = originalURL
        self.fileURL = fileURL
        self.from = from
        self.to = to
    }

    var isActive: Bool {
        switch state {
        case .waiting, .converting: true
        default: false
        }
    }

    var canUndo: Bool { originalInTrash != nil || keptOriginal != nil }
}

/// Renames that arrive together for the same folder and target format, such as a Finder batch rename.
/// A single rename is a batch of one.
@Observable final class Batch: Identifiable {
    let id = UUID()
    let folder: URL
    let to: Format
    var jobs: [Job] = []
    var lastAdded = Date()
    var summarized = false      // Its notification has been sent; later renames start a new batch
    var combinedURL: URL?       // When a batch renamed to PDF was merged into one file
    var combine: Bool?          // From Finder's menu: whether to merge its PDFs, whatever the Combine PDFs setting says

    init(folder: URL, to: Format) {
        self.folder = folder
        self.to = to
    }

    var isActive: Bool { jobs.contains(where: \.isActive) }
    var finishedCount: Int { jobs.count(where: { !$0.isActive }) }

    /// Fraction of the batch's work that's done, counting each file's own progress.
    var progress: Double {
        guard !jobs.isEmpty else { return 0 }
        let total = jobs.reduce(0.0) { sum, job in
            switch job.state {
            case .waiting: sum
            case .converting(let progress): sum + (progress ?? 0)
            default: sum + 1
            }
        }
        return total / Double(jobs.count)
    }
}

/// What happens to the original file after a conversion.
enum OriginalsMode: String, CaseIterable {
    case trash, keep, delete

    var title: String {
        switch self {
        case .trash: "Move to Trash"
        case .keep: "Keep next to the new file"
        case .delete: "Delete"
        }
    }
}

@Observable final class AppModel {
    var watchedFolders: [String] {
        didSet { defaults.set(watchedFolders, forKey: Keys.watchedFolders); restartWatcher() }
    }
    var isWatching: Bool {
        didSet { defaults.set(!isWatching, forKey: Keys.paused); restartWatcher() }
    }
    var originals: OriginalsMode {
        didSet { defaults.set(originals.rawValue, forKey: Keys.originals) }
    }
    var quality: Quality {
        didSet { defaults.set(quality.rawValue, forKey: Keys.quality) }
    }
    var combinePDFs: Bool {
        didSet { defaults.set(combinePDFs, forKey: Keys.combinePDFs) }
    }
    var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: Keys.notifications) }
    }
    var editableSlides: Bool {
        didSet { defaults.set(editableSlides, forKey: Keys.editableSlides) }
    }
    var exportAllPages: Bool {
        didSet { defaults.set(exportAllPages, forKey: Keys.allPages) }
    }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    /// Newest first.
    private(set) var batches: [Batch] = []

    var jobs: [Job] { batches.flatMap(\.jobs) }
    var hasActiveJobs: Bool { batches.contains(where: \.isActive) }

    /// Drives the breathing dot in the menu-bar icon. Only ticks while something is converting.
    private(set) var pulsePhase: Double = 0
    private var pulseTask: Task<Void, Never>?

    /// Overall progress for the menu-bar ring: a single file's own progress (nil when it doesn't report any),
    /// or, with several files on the go, how much of all of them is done.
    var activeProgress: Double? {
        let running = batches.filter(\.isActive)
        let jobs = running.flatMap(\.jobs)
        if jobs.count == 1 {
            if case .converting(let progress) = jobs[0].state { return progress }
            return nil
        }
        guard !jobs.isEmpty else { return nil }
        return running.reduce(0.0) { $0 + $1.progress * Double($1.jobs.count) } / Double(jobs.count)
    }

    /// How long after a rename another one still joins the same batch.
    private static let batchWindow: TimeInterval = 2

    private let defaults = UserDefaults.standard
    private let watcher = FolderWatcher()
    // Video and Keynote/Numbers/Pages jobs run one at a time; everything else a few at a time, so a big batch
    // doesn't start dozens of converters at once.
    private let heavyLane = Lane(limit: 1)
    private let lightLane = Lane(limit: max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ConvertAnything", category: "conversion")
    private var askedForNotifications = false
    private let notificationDelegate = NotificationDelegate()
    private let undoStore = UndoStore()
    /// Jobs whose undo is waiting for Finder to notice the rename (see `undo`).
    private var undoing: Set<ObjectIdentifier> = []

    private enum Keys {
        static let watchedFolders = "watchedFolders"
        static let paused = "paused"
        static let trashOriginals = "moveOriginalsToTrash"   // Older setting, replaced by `originals`
        static let originals = "originals"
        static let quality = "quality"
        static let combinePDFs = "combinePDFs"
        static let notifications = "showNotifications"
        static let allPages = "exportAllPages"
        static let editableSlides = "editableSlides"
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultFolders = ["Desktop", "Documents", "Downloads"].map { home.appending(path: $0).path }
        watchedFolders = defaults.stringArray(forKey: Keys.watchedFolders) ?? defaultFolders
        isWatching = !defaults.bool(forKey: Keys.paused)
        let oldTrashSetting = defaults.object(forKey: Keys.trashOriginals) as? Bool
        originals = defaults.string(forKey: Keys.originals).flatMap(OriginalsMode.init) ?? (oldTrashSetting == false ? .delete : .trash)
        quality = defaults.string(forKey: Keys.quality).flatMap(Quality.init) ?? .balanced
        combinePDFs = defaults.object(forKey: Keys.combinePDFs) as? Bool ?? true
        showNotifications = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        exportAllPages = defaults.object(forKey: Keys.allPages) as? Bool ?? true
        editableSlides = defaults.object(forKey: Keys.editableSlides) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled

        UNUserNotificationCenter.current().delegate = notificationDelegate
        watcher.onRename = { [weak self] from, to in self?.handleRename(from: from, to: to) }
        FinderMenuRequests.handler = { [weak self] request in self?.convert(request) }
        IWork.needsAttention = { [weak self] title, body in
            Task { @MainActor [weak self] in self?.notify(title, body: body, important: true) }
        }
        restartWatcher()
    }

    private func restartWatcher() {
        watcher.watch(isWatching ? watchedFolders : [])
    }

    // MARK: Deciding whether a rename is a conversion request

    private func handleRename(from oldURL: URL, to newURL: URL) {
        // Renaming a converted file back to its old name (also what ⌘Z in Finder does) restores the original.
        if let record = undoStore.match(converted: oldURL.path, original: newURL.path) {
            restoreOriginal(record, at: newURL)
            return
        }

        let name = newURL.lastPathComponent
        guard !name.hasPrefix("."), !name.hasPrefix("~$"),
              let oldFormat = Format(fileExtension: oldURL.pathExtension) else { return }
        guard let newFormat = Format(fileExtension: newURL.pathExtension) else {
            noteUnknownExtension(from: oldURL, to: newURL, oldFormat: oldFormat)
            return
        }
        guard oldFormat != newFormat else { return }   // Includes harmless renames like .jpg → .jpeg

        // A text file renamed to .json is only fixing its extension when it really holds JSON.
        if newFormat == .json && oldFormat == .txt && Sniffer.looksLikeJSON(newURL) { return }
        guard let source = sourceFormat(of: newURL, oldFormat: oldFormat) else { return }
        // Already in the new format: the rename just fixed a wrong extension.
        guard source != newFormat else { return }

        let job = Job(originalURL: oldURL, fileURL: newURL, from: source, to: newFormat)
        let folder = newURL.deletingLastPathComponent()
        let batch: Batch
        if let open = batches.first(where: {
            $0.folder == folder && $0.to == newFormat && !$0.summarized && $0.combine == nil
                && Date().timeIntervalSince($0.lastAdded) < Self.batchWindow
        }) {
            batch = open
        } else {
            batch = newBatch(folder: folder, to: newFormat)
        }
        start(job, in: batch)
    }

    private func newBatch(folder: URL, to format: Format) -> Batch {
        let batch = Batch(folder: folder, to: format)
        batches.insert(batch, at: 0)
        trimHistory()
        return batch
    }

    /// Adds a renamed file to a batch and converts it, or puts its name back when it can't become that format.
    private func start(_ job: Job, in batch: Batch) {
        batch.jobs.append(job)
        batch.lastAdded = Date()
        let source = job.from, newFormat = job.to

        guard Converter.route(from: source, to: newFormat) != nil else {
            revertRename(job)
            job.state = .failed(failureMessage(ConversionError.unsupported(source, newFormat), for: job))
            summarizeWhenFinished(batch)
            return
        }
        job.task = Task { await run(job) }
        updatePulse()
    }

    // MARK: Finder's "Convert to" menu

    /// Converts files chosen in Finder's "Convert to ▸" menu. Each one is renamed to the new extension and
    /// converted exactly as if the user had renamed it: the Originals setting, undo, Recent and notifications
    /// all work the same. It works in any folder, and while watching is paused, because it was asked for.
    ///
    /// Plain "PDF" gives one PDF per file. "Combine into One PDF" merges them into one whatever the Combine
    /// PDFs setting says, taking selected PDFs as they are; it goes in the first file's folder.
    func convert(_ request: FinderMenuRequests.Request) {
        let combine = request.choice == .combine
        let target: Format
        switch request.choice {
        case .format(let format): target = format
        case .combine: target = .pdf
        }
        let fileManager = FileManager.default
        var made: [URL: Batch] = [:]
        func batch(for file: URL) -> Batch {
            let folder = (combine ? request.files[0] : file).deletingLastPathComponent()
            if let batch = made[folder] { return batch }
            let batch = newBatch(folder: folder, to: target)
            batch.combine = combine
            made[folder] = batch
            return batch
        }

        for file in request.files {
            guard let oldFormat = Format(fileExtension: file.pathExtension), fileManager.fileExists(atPath: file.path) else { continue }
            if combine && oldFormat == .pdf {
                let job = Job(originalURL: file, fileURL: file, from: .pdf, to: .pdf)
                job.alreadyPDF = true
                job.state = .done
                job.resultURL = file
                let batch = batch(for: file)
                batch.jobs.append(job)
                batch.lastAdded = Date()
                continue
            }
            guard oldFormat != target else { continue }
            let renamed = uniqueFileURL(file.deletingPathExtension().appendingPathExtension(target.preferredExtension))
            do {
                // The folder watcher ignores the app's own renames, so this doesn't start a second conversion.
                try fileManager.moveItem(at: file, to: renamed)
            } catch {
                log.error("Finder menu couldn't rename \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                notify("Couldn't convert \(file.lastPathComponent)", body: error.localizedDescription)
                continue
            }
            guard let source = sourceFormat(of: renamed, oldFormat: oldFormat) else {
                try? fileManager.moveItem(at: renamed, to: file)
                notify("Couldn't convert \(file.lastPathComponent)", body: "Convert Anything can't read this file.")
                continue
            }
            // It already was the new format under a wrong extension: the rename fixed it.
            guard source != target else { continue }
            start(Job(originalURL: file, fileURL: renamed, from: source, to: target), in: batch(for: file))
        }
        for batch in made.values {
            if batch.jobs.isEmpty { batches.removeAll { $0 === batch } } else { summarizeWhenFinished(batch) }
        }
    }

    /// What's actually inside the file decides the source format, not the old extension.
    /// Nil when it's not something we understand, which is left alone.
    private func sourceFormat(of url: URL, oldFormat: Format) -> Format? {
        switch Sniffer.detect(url, claimed: oldFormat) {
        case .format(let detected): detected
        case .text: oldFormat.isPlainText ? oldFormat : .txt
        case .iWork: oldFormat.isIWork ? oldFormat : nil
        case .unknown: nil
        }
    }

    /// Extensions people add to keep a copy or mark a file, which aren't asking for a conversion.
    private static let notConversions: Set<String> = [
        "bak", "old", "orig", "tmp", "temp", "backup", "copy", "part", "crdownload", "download", "lock", "swp",
    ]
    private var unknownRenames: [(name: String, ext: String, message: String)] = []
    private var unknownFlush: Task<Void, Never>?

    /// A known kind of file renamed to an extension we don't know (.epub, .xyz): nothing is converted and the
    /// file keeps the name it was given, but the user hears why nothing happened. Only a plain extension swap
    /// on a file we can read counts, so saves that go through temporary names stay quiet. There's no history
    /// row (a row needs a target format), just a notification, and one for a whole batch rename.
    private func noteUnknownExtension(from oldURL: URL, to newURL: URL, oldFormat: Format) {
        let ext = newURL.pathExtension.lowercased()
        guard (1...6).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              !Self.notConversions.contains(ext),
              oldURL.deletingPathExtension().lastPathComponent == newURL.deletingPathExtension().lastPathComponent,
              showNotifications,
              let source = sourceFormat(of: newURL, oldFormat: oldFormat) else { return }
        unknownRenames.append((newURL.lastPathComponent, ext, UnsupportedConversion.unknownExtension(ext, from: source)))
        guard unknownFlush == nil else { return }
        unknownFlush = Task {
            try? await Task.sleep(for: .seconds(Self.batchWindow))
            let renames = unknownRenames
            unknownRenames = []
            unknownFlush = nil
            log.notice("\(renames.count) file(s) renamed to an extension we don't know: \(renames.map(\.ext).joined(separator: ","), privacy: .public)")
            if let only = renames.first, renames.count == 1 {
                notify("Couldn't convert \(only.name)", body: only.message)
            } else {
                let extensions = renames.map(\.ext).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                notify("Couldn't convert \(renames.count) files",
                       body: "Convert Anything doesn't know " + extensions.prefix(3).map { ".\($0)" }.joined(separator: ", ") + ".")
            }
        }
    }

    /// Plain words for a failure. A rename to a format that can't be made from the file also says what would work.
    private func failureMessage(_ error: Error, for job: Job) -> String {
        if case ConversionError.unsupported(let from, let to) = error {
            return UnsupportedConversion.message(from: from, to: to, originalExtension: job.originalURL.pathExtension)
        }
        return error.localizedDescription
    }

    // MARK: Running a conversion

    private func run(_ job: Job) async {
        defer {
            updatePulse()
            if let batch = batches.first(where: { $0.jobs.contains { $0 === job } }) { summarizeWhenFinished(batch) }
        }
        let lane = Converter.isHeavy(from: job.from, to: job.to) ? heavyLane : lightLane
        await lane.acquire()
        defer { lane.release() }

        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory.appending(path: "ConvertAnything/\(job.id.uuidString)")
        defer { try? fileManager.removeItem(at: workDir) }

        do {
            try Task.checkCancellation()
            job.state = .converting(progress: nil)
            try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Work on a private copy (an instant clone on APFS) so the user's file is untouched until the end.
            let input = workDir.appending(path: "input.\(job.from.rawValue)")
            try fileManager.copyItem(at: job.fileURL, to: input)

            let request = Converter.Request(
                input: input, from: job.from, to: job.to, workDir: workDir,
                title: job.fileURL.deletingPathExtension().lastPathComponent,
                originalDir: job.fileURL.deletingLastPathComponent(),
                allPages: exportAllPages,
                outputExtension: job.fileURL.pathExtension.lowercased(),
                editableSlides: editableSlides,
                quality: quality)
            let output = try await Converter.convert(request) { progress in
                Task { @MainActor in
                    if job.isActive { job.state = .converting(progress: progress) }
                }
            }
            try Task.checkCancellation()

            guard fileManager.fileExists(atPath: job.fileURL.path) else {
                throw ConversionError.failed("The file was moved or deleted while converting.")
            }

            switch originals {
            case .trash:
                // Trash the original under its original name, so it's easy to recognize.
                let backup = workDir.appending(path: job.originalURL.lastPathComponent)
                try fileManager.moveItem(at: input, to: backup)
                var trashed: NSURL?
                try fileManager.trashItem(at: backup, resultingItemURL: &trashed)
                job.originalInTrash = trashed as URL?
            case .keep:
                let keep = fileManager.fileExists(atPath: job.originalURL.path) ? uniqueFileURL(job.originalURL) : job.originalURL
                try fileManager.moveItem(at: input, to: keep)
                job.keptOriginal = keep
            case .delete:
                break
            }

            var isFolder: ObjCBool = false
            if fileManager.fileExists(atPath: output.path, isDirectory: &isFolder), isFolder.boolValue {
                // Every page became its own image: they go in a folder named after the file, which replaces it.
                // The renamed file still holds the original contents, which are already backed up.
                let folder = uniqueURL(job.fileURL.deletingPathExtension())
                try fileManager.moveItem(at: output, to: folder)
                try fileManager.removeItem(at: job.fileURL)
                job.resultURL = folder
                job.pageCount = try fileManager.contentsOfDirectory(atPath: folder.path).count
            } else {
                // Write the new contents into the renamed file itself rather than swapping in a new file,
                // so it stays the same file to Finder (keeping its tags and Finder's ⌘Z for the rename).
                try overwrite(job.fileURL, with: output)
                job.resultURL = job.fileURL
                if let trashed = job.originalInTrash {
                    undoStore.add(UndoRecord(converted: job.fileURL.path, original: job.originalURL.path,
                                             trashed: trashed.path, date: Date()))
                }
            }

            job.state = .done
        } catch is CancellationError {
            revertRename(job)
            job.state = .cancelled
        } catch ConversionError.cancelled {
            revertRename(job)
            job.state = .cancelled
        } catch {
            log.error("\(job.from.rawValue, privacy: .public) → \(job.to.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            revertRename(job)
            job.state = .failed(failureMessage(error, for: job))
        }
    }

    private func updatePulse() {
        if hasActiveJobs, pulseTask == nil {
            pulseTask = Task {
                // About 12 frames a second, one breath every 1.6 seconds.
                while !Task.isCancelled {
                    pulsePhase += 2 * .pi / 19
                    try? await Task.sleep(for: .milliseconds(84))
                }
            }
        } else if !hasActiveJobs {
            pulseTask?.cancel()
            pulseTask = nil
            pulsePhase = 0
        }
    }

    /// Sends one notification for the whole batch once all its files are finished and no more renames
    /// are arriving for it.
    private func summarizeWhenFinished(_ batch: Batch) {
        guard !batch.isActive, !batch.summarized else { return }
        Task {
            let wait = batch.lastAdded.addingTimeInterval(Self.batchWindow).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !batch.isActive, !batch.summarized,
                  Date().timeIntervalSince(batch.lastAdded) >= Self.batchWindow else { return }
            batch.summarized = true
            if batch.combine ?? combinePDFs, batch.to == .pdf { await combine(batch) }
            summarize(batch)
        }
    }

    /// Merges a batch's new PDFs (in name order) into one "Combined.pdf" and trashes the separate ones.
    private func combine(_ batch: Batch) async {
        let pdfs = batch.jobs.filter { $0.state == .done }.compactMap(\.resultURL)
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard pdfs.count > 1 else { return }
        let combined = uniqueFileURL(batch.folder.appending(path: "Combined.pdf"))
        do {
            try await Task.detached(priority: .utility) {
                let merged = PDFDocument()
                for url in pdfs {
                    guard let document = PDFDocument(url: url) else { continue }
                    for index in 0..<document.pageCount {
                        if let page = document.page(at: index) { merged.insert(page, at: merged.pageCount) }
                    }
                }
                guard merged.write(to: combined) else { throw ConversionError.failed("Couldn't write the combined PDF.") }
            }.value
            // The separate PDFs go to the Trash. Selected PDFs that went in as they were are originals, so they follow the Originals setting.
            for url in pdfs {
                let selected = batch.jobs.first { $0.alreadyPDF && $0.fileURL == url }
                switch selected != nil ? originals : .trash {
                case .trash:
                    var trashed: NSURL?
                    try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                    selected?.originalInTrash = trashed as URL?   // So Undo can put it back
                case .delete: try? FileManager.default.removeItem(at: url)
                case .keep: break
                }
            }
            batch.jobs.forEach { undoStore.remove(converted: $0.fileURL.path) }
            batch.jobs.filter { $0.resultURL.map(pdfs.contains) == true }.forEach { $0.combinedInto = combined }
            batch.combinedURL = combined
        } catch {
            log.error("Combining PDFs failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func summarize(_ batch: Batch) {
        let done = batch.jobs.filter { $0.state == .done }
        let failed = batch.jobs.compactMap { job -> (Job, String)? in
            if case .failed(let message) = job.state { (job, message) } else { nil }
        }
        log.notice("Batch to \(batch.to.rawValue, privacy: .public) finished: \(done.count) converted, \(failed.count) failed, \(batch.jobs.count) total")

        if batch.jobs.count == 1, let job = batch.jobs.first {
            if job.state == .done, let result = job.resultURL {
                let detail = job.pageCount.map { " · \($0) \(job.to.kind == .image ? "images" : "files")" } ?? ""
                notify("Converted \(result.lastPathComponent)", body: "\(job.from.displayName) → \(job.to.displayName)\(detail)",
                       reveal: [result])
            } else if let (job, message) = failed.first {
                notify("Couldn't convert \(job.originalURL.lastPathComponent)", body: message)
            }
            return
        }

        let target = batch.to.displayName
        if let combined = batch.combinedURL {
            let skipped = failed.isEmpty ? "" : " · \(failed.count) couldn't be converted"
            notify("Combined \(done.count) files into \(combined.lastPathComponent)", body: "In \(batch.folder.lastPathComponent)\(skipped)",
                   reveal: [combined])
        } else if failed.isEmpty {
            guard !done.isEmpty else { return }   // Everything was cancelled
            notify("Converted \(done.count) files to \(target)", body: "In \(batch.folder.lastPathComponent)",
                   reveal: done.compactMap(\.resultURL))
        } else if done.isEmpty {
            notify("Couldn't convert \(failed.count) files to \(target)", body: failed[0].1)
        } else {
            let names = failed.prefix(3).map { $0.0.originalURL.lastPathComponent }.joined(separator: ", ")
            let more = failed.count > 3 ? " and \(failed.count - 3) more" : ""
            notify("Converted \(done.count) of \(done.count + failed.count) files to \(target)",
                   body: "Not converted: \(names)\(more)", reveal: done.compactMap(\.resultURL))
        }
    }

    /// Puts the old name back so the file's extension matches its contents again.
    private func revertRename(_ job: Job) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: job.fileURL.path),
              !fileManager.fileExists(atPath: job.originalURL.path) else { return }
        try? fileManager.moveItem(at: job.fileURL, to: job.originalURL)
    }

    /// The converted file now has its old name again: put the original back in its place.
    private func restoreOriginal(_ record: UndoRecord, at url: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            try fileManager.moveItem(at: URL(fileURLWithPath: record.trashed), to: url)
            undoStore.remove(converted: record.converted)
            jobs.first { $0.state == .done && $0.fileURL.path == record.converted }?.state = .undone
            notify("Restored \(url.lastPathComponent)", body: "The original is back. The converted file is in the Trash.")
        } catch {
            notify("Couldn't restore \(url.lastPathComponent)", body: error.localizedDescription)
        }
    }

    // MARK: Actions from the menu

    func cancel(_ job: Job) {
        job.task?.cancel()
    }

    /// Trashes the converted file (or folder of images) and brings the original back from the Trash.
    func undo(_ job: Job) {
        guard job.state == .done, job.originalInTrash != nil || job.keptOriginal != nil,
              !undoing.contains(ObjectIdentifier(job)) else { return }
        let fileManager = FileManager.default
        let result = job.resultURL ?? job.fileURL
        do {
            guard let trashed = job.originalInTrash else {
                // With "Keep both" the original is already there; undoing just removes the converted file.
                if fileManager.fileExists(atPath: result.path) {
                    try fileManager.trashItem(at: result, resultingItemURL: nil)
                }
                finishUndo(job)
                return
            }
            guard !fileManager.fileExists(atPath: job.originalURL.path) else {
                throw ConversionError.failed("A file named \(job.originalURL.lastPathComponent) already exists.")
            }
            guard fileManager.fileExists(atPath: trashed.path) else {
                throw ConversionError.failed("The original is no longer in the Trash.")
            }
            guard fileManager.fileExists(atPath: result.path) else {
                try fileManager.moveItem(at: trashed, to: job.originalURL)
                finishUndo(job)
                return
            }
            // Do what ⌘Z in Finder does: give the converted file (or folder) the original's name first, wait for
            // Finder to notice, then swap the original in under that same name. Finder then keeps the icon where it
            // was instead of placing the original as a new file. (The watcher ignores the app's own renames.)
            try fileManager.moveItem(at: result, to: job.originalURL)
            undoing.insert(ObjectIdentifier(job))
            Task {
                // Finder needs about half a second to pick up a rename; without it the icon still jumps.
                try? await Task.sleep(for: .seconds(1))
                defer { undoing.remove(ObjectIdentifier(job)) }
                do {
                    try fileManager.trashItem(at: job.originalURL, resultingItemURL: nil)
                } catch {
                    try? fileManager.moveItem(at: job.originalURL, to: result)
                    notify("Couldn't undo", body: error.localizedDescription)
                    return
                }
                do {
                    try fileManager.moveItem(at: trashed, to: job.originalURL)
                    finishUndo(job)
                } catch {
                    notify("Couldn't undo", body: "\(error.localizedDescription) Both files are in the Trash.")
                }
            }
        } catch {
            notify("Couldn't undo", body: error.localizedDescription)
        }
    }

    private func finishUndo(_ job: Job) {
        undoStore.remove(converted: job.fileURL.path)
        job.state = .undone
    }

    /// Selects the file in Finder. If it has been moved or deleted since, opens its folder and marks the row.
    func reveal(_ job: Job) {
        let url = job.combinedInto ?? (job.state == .done ? job.resultURL ?? job.fileURL : job.originalURL)
        let found = FinderReveal.show([url])
        if job.state == .done { job.resultMissing = !found }
    }

    func cancel(_ batch: Batch) {
        batch.jobs.filter(\.isActive).forEach { $0.task?.cancel() }
    }

    func undoAll(_ batch: Batch) {
        batch.jobs.filter { $0.state == .done && $0.canUndo }.forEach(undo)
        if let combined = batch.combinedURL, FileManager.default.fileExists(atPath: combined.path) {
            try? FileManager.default.trashItem(at: combined, resultingItemURL: nil)
            batch.combinedURL = nil
        }
    }

    /// Selects the converted files in Finder, or the folder if none were converted.
    func reveal(_ batch: Batch) {
        let results = batch.combinedURL.map { [$0] } ?? batch.jobs.filter { $0.state == .done }.compactMap(\.resultURL)
        FinderReveal.show(results.isEmpty ? [batch.folder] : results, in: batch.folder)
    }

    func clearFinished() {
        batches.removeAll { !$0.isActive }
    }

    #if DEBUG
    /// Fills the history with made-up conversions, for previews and UI snapshots. Pause watching first.
    func showSamples(_ samples: [Batch]) {
        batches = samples
    }
    #endif

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.map(\.path).filter { !watchedFolders.contains($0) }
        watchedFolders += new
    }

    func removeFolder(_ path: String) {
        watchedFolders.removeAll { $0 == path }
    }

    /// "deck", then "deck 2", "deck 3"… if that name is taken.
    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent) \(number)")
            number += 1
        }
        return candidate
    }

    /// "notes.md", then "notes 2.md", "notes 3.md"… if that name is taken.
    private func uniqueFileURL(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent(), ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = url
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Replaces a file's contents in place, in 8 MB chunks.
    private func overwrite(_ file: URL, with source: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? reader.close(); try? writer.close() }
        try writer.truncate(atOffset: 0)
        while let chunk = try reader.read(upToCount: 8 << 20), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
    }

    /// Keeps the 20 most recent finished batches (a batch counts once, however many files it has).
    private func trimHistory() {
        var finished = 0
        batches.removeAll { batch in
            guard !batch.isActive else { return false }
            finished += 1
            return finished > 20
        }
    }

    // MARK: Notifications

    /// `important` notifications (an app is waiting for you) are shown even with "Notify when conversions finish" off.
    private func notify(_ title: String, body: String, reveal: [URL] = [], important: Bool = false) {
        guard showNotifications || important else { return }
        let center = UNUserNotificationCenter.current()
        if !askedForNotifications {
            askedForNotifications = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !reveal.isEmpty { content.userInfo = ["reveal": reveal.map(\.path)] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Shows banners even while the app's menu is open, and opens the file in Finder when one is clicked.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let paths = response.notification.request.content.userInfo["reveal"] as? [String] else { return }
        await FinderReveal.show(paths.map { URL(fileURLWithPath: $0) })
    }
}

/// Lets up to `limit` tasks through at once; the rest wait their turn in order.
final class Lane {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        guard running >= limit else { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }   // The releasing task hands over its slot
    }

    func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}
