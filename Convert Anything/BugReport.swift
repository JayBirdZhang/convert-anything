import Foundation
import OSLog
import UniformTypeIdentifiers

/// A bug report as a link: a pre-filled Google Form (no account needed) or a pre-filled GitHub issue.
/// Nothing is sent from the app. The browser shows every field, and the person sends it or doesn't.
/// Nothing here runs until a Report button is pressed.
nonisolated struct BugReport: Sendable {
    var conversion: String?      // "mp4 → txt", for a report about a failed conversion
    var errorMessage: String?
    var log: [String] = []       // Oldest first
    var appVersion = Diagnostics.appVersion
    var macOSVersion = Diagnostics.macOSVersion
    var macModel = Diagnostics.macModel

    // MARK: - Where reports go

    /// "Convert Anything — Bug Report": its public ID, and its questions from ⋮ › Pre-fill form.
    enum Form {
        static let id = "1FAIpQLSewlzUAIc8do6rgnxzBNy0QMGjqmnADiSWi0FUIAzFDU57S5g"
        static let whatHappened = "entry.249791518"   // What happened? (left for the reporter)
        static let appVersion = "entry.2030405449"     // App version
        static let macOSVersion = "entry.1997545783"   // macOS version
        static let macModel = "entry.65164408"       // Mac model
        static let conversion = "entry.1366513454"     // Conversion
        static let errorMessage = "entry.319493321"   // Error message
        static let log = "entry.433755357"            // Recent log
        static let email = "entry.1727194320"          // Contact email (optional; left for the reporter)
    }
    static let repository = "https://github.com/JayBirdZhang/Convert-Anything"

    /// Google answers 400 above about 8,000 characters; this leaves room for headers and cookies.
    static let formLimit = 6000
    /// Signed-out visitors are sent through github.com/login, which encodes the whole URL again
    /// (each escape triples) and breaks above roughly 5,500 characters. See `githubCost`.
    static let issueLimit = 4500
    static let maxLogLines = 20
    static let maxLineLength = 300
    static let maxErrorLength = 1000

    // MARK: - URLs

    var formURL: URL {
        fitted(limit: Self.formLimit, cost: { $0.count }) { report in
            Self.url("https://docs.google.com/forms/d/e/\(Form.id)/viewform", [
                ("usp", "pp_url"),
                (Form.appVersion, report.appVersion),
                (Form.macOSVersion, report.macOSVersion),
                (Form.macModel, report.macModel),
                (Form.conversion, report.conversion),
                (Form.errorMessage, report.errorMessage),
                (Form.log, report.log.isEmpty ? nil : report.log.joined(separator: "\n")),
            ])
        }
    }

    var issueURL: URL {
        fitted(limit: Self.issueLimit, cost: Self.githubCost) { report in
            let title = report.conversion.map { "\($0) conversion failed" } ?? ""
            var body = "### What happened?\n\n\n\n### Details\n\n"
            body += "- App version: \(report.appVersion)\n- macOS: \(report.macOSVersion)\n- Mac model: \(report.macModel)\n"
            if let conversion = report.conversion { body += "- Conversion: \(conversion)\n" }
            if let error = report.errorMessage { body += "\n**Error message**\n\n```\n\(error)\n```\n" }
            if !report.log.isEmpty {
                body += "\n<details><summary>Recent log</summary>\n\n```\n\(report.log.joined(separator: "\n"))\n```\n</details>\n"
            }
            return Self.url(Self.repository + "/issues/new", [("title", title), ("body", body)])
        }
    }

    /// Builds the URL, trimming until it fits: a long error to its first 500 characters,
    /// then the oldest log lines, then the error a quarter at a time.
    private func fitted(limit: Int, cost: (String) -> Int, build: (BugReport) -> String) -> URL {
        var report = self
        var string = build(report)
        while cost(string) > limit {
            if let error = report.errorMessage, error.count > 500 {
                report.errorMessage = String(error.prefix(499)) + "…"
            } else if !report.log.isEmpty {
                report.log.removeFirst()
            } else if let error = report.errorMessage, error.count > 40 {
                report.errorMessage = String(error.prefix(error.count * 3 / 4)) + "…"
            } else if report.errorMessage != nil {
                report.errorMessage = nil
            } else {
                break   // Only the short system details are left
            }
            string = build(report)
        }
        return URL(string: string)!
    }

    /// The length of the login URL a signed-out visitor is redirected through: every character
    /// that isn't unreserved gets encoded once more, so "%20" becomes "%2520".
    static func githubCost(_ url: String) -> Int {
        url.count + 2 * url.unicodeScalars.count { !unreserved.contains($0) }
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Escapes everything but unreserved characters. URLComponents would leave "+" alone, which forms read as a space.
    private static func url(_ base: String, _ items: [(String, String?)]) -> String {
        base + "?" + items.compactMap { name, value in
            value.map { "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: unreserved)!)" }
        }.joined(separator: "&")
    }

    // MARK: - The log

    /// The app's last few log entries from the past half hour, redacted. Takes a moment, so call it off the main thread.
    static func recentLog(minutes: Double = 30, redactor: Redactor) -> [String] {
        let since = Date(timeIntervalSinceNow: -minutes * 60)
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: since),
                                                  matching: NSPredicate(format: "subsystem BEGINSWITH %@", Diagnostics.subsystem))
        else { return [] }
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries where entry.date >= since {
            lines.append("\(time.string(from: entry.date)) [\(entry.category)] \(level(entry.level))\(entry.composedMessage)")
            if lines.count > maxLogLines { lines.removeFirst() }
        }
        return lines.map { line in
            let clean = redactor(line)
            return clean.count > maxLineLength ? String(clean.prefix(maxLineLength - 1)) + "…" : clean
        }
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .error: "error: "
        case .fault: "fault: "
        default: ""
        }
    }
}

/// Takes file names, paths and the person's name out of text before it goes in a report.
/// When it can't tell where a name ends, it removes too much rather than too little.
nonisolated struct Redactor: Sendable {
    /// File and folder names known to be in the text, e.g. the ones a failed conversion was about.
    var names: [String] = []
    var home = NSHomeDirectory()
    var userNames = [NSFullUserName(), NSUserName()]

    func callAsFunction(_ text: String) -> String {
        var s = text
        // Known names first, longest first, so "Tax Return.pdf" goes before "Tax Return".
        for name in Set(names).filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            let word = #"(?i)(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#
            s = replace(word, in: s) { _ in "‹file›" }
        }
        // Percent-encoded, so it ends at whitespace or the end of its {UserInfo}; not at a trailing comma.
        s = replace(#"file://[^\s"“”<>}]*[^\s"“”<>},.;]"#, in: s) { _ in "‹path›" }
        s = redactPaths(s)
        s = replace(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+"#, in: s) { _ in "‹email›" }
        // Apple quotes file names in curly quotes: The file “Report.docx” couldn’t be opened.
        s = replace(#"“[^”\n]*”"#, in: s) { _ in "“‹file›”" }
        // Other quotes, when what's inside looks like a file name (it may have spaces).
        s = replace(#"(?<![\p{L}\p{N}])(["'‘])([^"'‘’\n/]{1,255}\.[A-Za-z0-9]{1,8})(["'’])(?![\p{L}\p{N}])"#, in: s) { m in
            m[2].contains(". ") ? m[0] : m[1] + "‹file›" + m[3]
        }
        // Any word that ends in a known file extension: notes.md, IMG_0042.HEIC
        s = replace(#"[^\s/"'“”‘’()\[\]{}<>,;:=*|]+\.([A-Za-z][A-Za-z0-9]{0,7})\b"#, in: s) { m in
            Self.isFileExtension(m[1]) ? "‹file›" : m[0]
        }
        for user in Set(userNames).filter({ $0.count >= 3 }) {
            s = replace(#"(?i)\b"# + NSRegularExpression.escapedPattern(for: user) + #"\b"#, in: s) { _ in "‹user›" }
        }
        return s
    }

    /// Every absolute or home-relative path, from where it starts to the end of its last file name
    /// (or, with no file name to go by, to the next delimiter): "/Users/jay/My Report.docx" becomes "~/…".
    private func redactPaths(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let startsPath = (chars[i] == "/" || (chars[i] == "~" && i + 1 < chars.count && chars[i + 1] == "/"))
                && (i == 0 || Self.beforePath.contains(chars[i - 1]))
            let next = chars[i] == "~" ? i + 2 : i + 1
            guard startsPath, next < chars.count, !chars[next].isWhitespace, chars[next] != "/" || chars[i] == "~" else {
                out.append(chars[i])
                i += 1
                continue
            }
            // Names can hold spaces, commas and parentheses, so only a clear delimiter ends a path:
            // an unbalanced ")", or a comma before the next "Key=" of an error's UserInfo.
            var end = i, depth = 0
            scan: while end < chars.count {
                switch chars[end] {
                case "(": depth += 1
                case ")": if depth == 0 { break scan } else { depth -= 1 }
                case ",": if Self.keyFollows(chars, at: end + 1) { break scan }
                case let c where Self.afterPath.contains(c): break scan
                default: break
                }
                end += 1
            }
            // Stop after the file name that ends the last path component, so the rest of the sentence survives.
            if let slash = chars[i..<end].lastIndex(of: "/") {
                let tail = String(chars[slash..<end])
                if let last = Self.fileNameEnd.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
                   let range = Range(last.range, in: tail) {
                    end = slash + tail.distance(from: tail.startIndex, to: range.upperBound)
                }
            }
            out += replacement(for: String(chars[i..<end]))
            i = end
        }
        return out
    }

    private func replacement(for path: String) -> String {
        if path.hasPrefix("~/") || path == home || path.hasPrefix(home + "/") { return "~/…" }
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        return Self.systemFolders.contains(first) ? "/\(first)/…" : "/…"
    }

    private static let fileNameEnd = try! NSRegularExpression(pattern: #"\.[A-Za-z0-9]{1,8}(?=[\s.]|$)"#)
    private static let beforePath: Set<Character> = [" ", "\t", "\n", "\"", "'", "“", "‘", "(", "[", "{", "<", "=", ":", ","]
    private static let afterPath: Set<Character> = ["\n", "\"", "”", "]", "}", ">", "|"]

    /// " NSUnderlyingError=…": the next entry of a UserInfo dictionary, or nothing more at all.
    private static func keyFollows(_ chars: [Character], at start: Int) -> Bool {
        var j = start
        while j < chars.count, chars[j] == " " { j += 1 }
        guard j < chars.count else { return true }
        let keyStart = j
        while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
        return j > keyStart && j < chars.count && chars[j] == "="
    }
    private static let systemFolders: Set<String> = ["Users", "Volumes", "private", "var", "tmp", "Applications",
                                                     "Library", "System", "usr", "opt", "dev", "etc"]

    private static func isFileExtension(_ ext: String) -> Bool {
        let ext = ext.lowercased()
        if ["avif", "jxl", "cr3", "opus", "srt", "vtt", "webp", "md", "epub", "odt", "numbers", "pages", "key"].contains(ext) {
            return true
        }
        return UTType(filenameExtension: ext).map { !$0.isDynamic } ?? false
    }

    /// Replaces each match with what `with` returns for its capture groups (0 is the whole match).
    private func replace(_ pattern: String, in text: String, with: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map {
                match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0))
            }
            out += with(groups)
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }
}
