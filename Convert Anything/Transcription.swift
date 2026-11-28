import AVFoundation
import Speech

/// Writes down what's said in audio and video, entirely on this Mac: SpeechAnalyzer on macOS 26 and later,
/// the older SFSpeechRecognizer (forced to stay on-device) before that. Nothing is uploaded.
nonisolated enum Transcription {
    @concurrent
    static func convert(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let audio = try await openAudio(request, progress: progress)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration > 0 else { throw ConversionError.failed("This file has no sound to transcribe.") }
        // A video's soundtrack was decoded first and already filled the first 5% of the bar.
        let base = audio.url.lastPathComponent == extractedName ? 0.05 : 0
        let progress: @Sendable (Double) -> Void = { progress(base + (1 - base) * $0) }

        var tokens: [Transcript.Token]
        if #available(macOS 26, *), SpeechTranscriber.isAvailable, !forceLegacy {
            tokens = try await ModernEngine.transcribe(audio, duration: duration, progress: progress)
        } else {
            tokens = try await LegacyEngine.transcribe(audio, duration: duration, progress: progress)
        }
        tokens.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !tokens.isEmpty else { throw ConversionError.failed("No speech was found in this file.") }

        let text: String
        switch request.to {
        case .srt: text = Transcript.srt(Transcript.cues(from: tokens))
        case .vtt: text = Transcript.vtt(Transcript.cues(from: tokens))
        default: text = Transcript.paragraphs(from: tokens)
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    /// Lets tests try the pre-macOS 26 engine on a newer Mac.
    private static var forceLegacy: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CONVERT_ANYTHING_LEGACY_SPEECH"] != nil
        #else
        false
        #endif
    }

    /// Audio files are read as they are. A video's sound is first decoded into a small 16 kHz mono file
    /// (all speech recognition needs), streaming, so the whole soundtrack is never in memory.
    private static func openAudio(_ request: Converter.Request, progress: @Sendable (Double) -> Void) async throws -> AVAudioFile {
        if request.from.kind == .audio, let file = try? AVAudioFile(forReading: request.input) { return file }

        let asset = AVURLAsset(url: request.input)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.failed("This file has no sound to transcribe.")
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        ]
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? ConversionError.failed("Couldn't read this file's sound.") }

        let url = request.workDir.appending(path: extractedName)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = file.processingFormat
        var reported = 0.0
        while let sample = trackOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                into: buffer.mutableAudioBufferList) == noErr else { continue }
            try file.write(from: buffer)
            // Decoding is quick next to recognizing, so it gets the first few percent of the bar.
            let done = duration > 0 ? min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration) : 0
            if done - reported >= 0.05 { reported = done; progress(0.05 * done) }
        }
        if reader.status == .failed { throw reader.error ?? ConversionError.failed("Couldn't read this file's sound.") }
        return try AVAudioFile(forReading: url)
    }

    private static let extractedName = "speech.caf"

    /// The system's language when speech recognition knows it, otherwise English.
    static func languageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Recognized text inside a script that doesn't put spaces between words (Chinese, Japanese, Thai).
    static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(scalar) || (0xF900...0xFAFF).contains(scalar) || (0xFF00...0xFFEF).contains(scalar)
            || (0x0E00...0x0E7F).contains(scalar)
    }
}

// MARK: - macOS 26 and later

/// SpeechAnalyzer reads the file itself, as fast as the Neural Engine allows, with no length limit.
@available(macOS 26, *)
nonisolated private enum ModernEngine {
    static func transcribe(_ audio: AVAudioFile, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.Token] {
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale else {
            throw ConversionError.failed("Speech recognition isn't available on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // Each language's model is a separate system download, made the first time it's needed.
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let watcher = Task {
                while !Task.isCancelled {
                    progress(installation.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            do {
                try await installation.downloadAndInstall()
            } catch {
                if Task.isCancelled { throw ConversionError.cancelled }
                throw ConversionError.failed("The speech model for \(Transcription.languageName(locale)) isn't on this Mac yet and couldn't be downloaded. Connect to the internet once and try again.")
            }
        }

        // Released as soon as the file is done, so the model doesn't sit in memory while the app idles.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .whileInUse))
        let collector = Task {
            var tokens: [Transcript.Token] = []
            for try await result in transcriber.results {
                append(result, to: &tokens)
                progress(min(1, result.range.end.seconds / duration))
            }
            return tokens
        }
        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(from: audio) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            // Finishing the analyzer ends the results too, so the collector can't be left waiting.
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw Task.isCancelled ? ConversionError.cancelled : error
        }
        let tokens = try await collector.value
        if Task.isCancelled { throw ConversionError.cancelled }
        return tokens
    }

    /// Each timed run is a word; the untimed text between them (spaces, punctuation) stays with the word before it.
    private static func append(_ result: SpeechTranscriber.Result, to tokens: inout [Transcript.Token]) {
        let text = result.text
        var first = true
        for run in text.runs {
            var piece = String(text[run.range].characters)
            if first, let last = tokens.last?.text.last, let next = piece.first,
               !last.isWhitespace, !next.isWhitespace, !(Transcription.isUnspaced(last) && Transcription.isUnspaced(next)) {
                tokens[tokens.count - 1].text += " "
            }
            if let range = run.audioTimeRange {
                tokens.append(.init(text: piece, start: range.start.seconds, end: range.end.seconds))
            } else if !tokens.isEmpty && !first {
                tokens[tokens.count - 1].text += piece
            } else {
                piece = piece.trimmingCharacters(in: .whitespaces)
                tokens.append(.init(text: piece, start: result.range.start.seconds, end: result.range.start.seconds))
            }
            first = false
        }
    }
}

// MARK: - macOS 14 and 15

/// SFSpeechRecognizer, kept on-device. It works on about a minute of audio at a time and forgets what came
/// before a long pause, so the audio is fed in pieces cut at each pause, or at the quietest moment before
/// 55 seconds when the speaker doesn't stop.
nonisolated private enum LegacyEngine {
    static let sampleRate = 16_000.0

    static func transcribe(_ audio: AVAudioFile, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.Token] {
        try await authorize()
        let preferred = SFSpeechRecognizer(locale: .current)
        guard let recognizer = preferred ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw ConversionError.failed("Speech recognition isn't available on this Mac.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw ConversionError.failed("This Mac can't recognize \(Transcription.languageName(recognizer.locale)) speech without the internet. Turn on Dictation in System Settings › Keyboard to download it, then try again.")
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: audio.processingFormat, to: format) else {
            throw ConversionError.failed("Couldn't read this file's sound.")
        }
        let maxChunk = Int(55 * sampleRate), searchFrom = Int(40 * sampleRate)
        var samples: [Float] = []
        var offset = 0.0
        var tokens: [Transcript.Token] = []
        var finished = false
        while !finished || !samples.isEmpty {
            try Task.checkCancellation()
            if !finished { finished = try read(audio, through: converter, into: &samples, upTo: maxChunk) }
            let cut = firstPause(in: samples, limit: maxChunk)
                ?? (samples.count > maxChunk ? quietestPoint(in: samples, from: searchFrom, to: maxChunk) : samples.count)
            // A silent piece (the quiet tail after the last words) makes the old recognizer invent a word.
            if hasSound(samples[0..<cut]) {
                tokens += try await recognize(samples[0..<cut], offset: offset, with: recognizer, format: format)
            }
            samples.removeFirst(cut)
            offset += Double(cut) / sampleRate
            progress(min(1, offset / duration))
        }
        return tokens
    }

    private static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else {
            throw ConversionError.failed("Convert Anything isn't allowed to recognize speech. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
        }
    }

    /// Converts audio to 16 kHz mono until `samples` holds `limit` samples. Returns true at the end of the file.
    private static func read(_ audio: AVAudioFile, through converter: AVAudioConverter, into samples: inout [Float], upTo limit: Int) throws -> Bool {
        let chunk: AVAudioFrameCount = 16_000
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: chunk),
              let input = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 32_768) else { return true }
        while samples.count < limit {
            var readError: Error?
            var ended = false
            let status = converter.convert(to: output, error: nil) { _, inputStatus in
                do {
                    try audio.read(into: input)
                } catch {
                    readError = error
                }
                if input.frameLength == 0 || readError != nil {
                    ended = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let readError, audio.framePosition < audio.length { throw readError }
            if status == .error { throw ConversionError.failed("Couldn't read this file's sound.") }
            if let data = output.floatChannelData, output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || (ended && output.frameLength == 0) { return true }
        }
        return false
    }

    /// The middle of the first pause of 0.7 seconds or more (quieter than -40 dB) that follows some sound,
    /// within the first `limit` samples.
    private static func firstPause(in samples: [Float], limit: Int) -> Int? {
        let window = Int(sampleRate / 20), needed = Int(0.7 * sampleRate)
        var heard = false, quiet = 0, position = 0
        let end = min(samples.count, limit)
        while position + window <= end {
            var energy: Float = 0
            for index in position..<position + window { energy += samples[index] * samples[index] }
            if energy / Float(window) < 1e-4 {
                quiet += window
                if heard && quiet >= needed { return position + window - quiet / 2 }
            } else {
                heard = true
                quiet = 0
            }
            position += window
        }
        return nil
    }

    /// Whether any twentieth of a second is louder than the pause threshold.
    private static func hasSound(_ samples: ArraySlice<Float>) -> Bool {
        let window = Int(sampleRate / 20)
        var position = samples.startIndex
        while position + window <= samples.endIndex {
            var energy: Float = 0
            for index in position..<position + window { energy += samples[index] * samples[index] }
            if energy / Float(window) >= 1e-4 { return true }
            position += window
        }
        return false
    }

    /// The start of the quietest tenth of a second between `start` and `end`.
    private static func quietestPoint(in samples: [Float], from start: Int, to end: Int) -> Int {
        let window = Int(sampleRate / 10)
        var best = end, lowest = Float.greatestFiniteMagnitude
        var position = start
        while position + window <= end {
            var energy: Float = 0
            for index in position..<position + window { energy += samples[index] * samples[index] }
            if energy < lowest { lowest = energy; best = position + window / 2 }
            position += window / 2
        }
        return best
    }

    /// One piece of audio through the recognizer. Every final result is kept, since a long pause can end one.
    private static func recognize(_ samples: ArraySlice<Float>, offset: Double, with recognizer: SFSpeechRecognizer,
                                  format: AVAudioFormat) async throws -> [Transcript.Token] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()

        let state = RecognitionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.start(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        state.add(tokens(in: result.bestTranscription, offset: offset))
                    }
                    if let error {
                        // "No speech detected" just means this piece was silent or music.
                        let nsError = error as NSError
                        state.finish(nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 ? nil : error)
                    } else if result?.isFinal == true {
                        state.finish(nil)
                    }
                }
                state.task = task
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Each word with the spaces and punctuation that follow it, so the words joined give back the full text.
    private static func tokens(in transcription: SFTranscription, offset: Double) -> [Transcript.Token] {
        let text = transcription.formattedString as NSString
        let segments = transcription.segments
        return segments.enumerated().map { index, segment in
            let start = index == 0 ? 0 : segment.substringRange.location
            let end = index + 1 < segments.count ? segments[index + 1].substringRange.location : text.length
            let piece = text.substring(with: NSRange(location: start, length: max(0, end - start)))
            return .init(text: piece, start: offset + segment.timestamp, end: offset + segment.timestamp + segment.duration)
        }
    }

    /// Hands the recognizer's callbacks to the waiting task exactly once, whatever order they arrive in.
    private final class RecognitionState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[Transcript.Token], Error>?
        private var tokens: [Transcript.Token] = []
        private var cancelled = false
        var task: SFSpeechRecognitionTask? {
            get { lock.withLock { _task } }
            set { lock.withLock { _task = newValue }; if lock.withLock({ cancelled }) { newValue?.cancel() } }
        }
        private var _task: SFSpeechRecognitionTask?

        func start(_ continuation: CheckedContinuation<[Transcript.Token], Error>) {
            let alreadyCancelled = lock.withLock { () -> Bool in self.continuation = continuation; return cancelled }
            if alreadyCancelled { finish(ConversionError.cancelled) }
        }

        func add(_ more: [Transcript.Token]) { lock.withLock { tokens += more } }

        func finish(_ error: Error?) {
            let (continuation, tokens) = lock.withLock { () -> (CheckedContinuation<[Transcript.Token], Error>?, [Transcript.Token]) in
                defer { self.continuation = nil }
                return (self.continuation, self.tokens)
            }
            if let error { continuation?.resume(throwing: error) } else { continuation?.resume(returning: tokens) }
        }

        func cancel() {
            let task = lock.withLock { () -> SFSpeechRecognitionTask? in cancelled = true; return _task }
            task?.cancel()
            finish(ConversionError.cancelled)
        }
    }
}

// MARK: - Writing it out

/// Timed words → readable paragraphs or subtitle cues. Shared by both engines and by subtitle files.
nonisolated enum Transcript {
    /// A word (or, in Chinese and Japanese, a few characters) with the spaces and punctuation after it, and when it was said.
    struct Token: Sendable, Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    struct Cue: Sendable, Equatable {
        var start: Double
        var end: Double
        var lines: [String]
    }

    static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]

    static func endsSentence(_ token: Token) -> Bool {
        var text = Substring(token.text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = text.last, "\"'”’)]".contains(last) { text = text.dropLast() }
        return text.last.map(sentenceEnds.contains) ?? false
    }

    /// Plain text with a new paragraph wherever the speaker pauses at the end of a sentence, or pauses for
    /// long in the middle of one. Very long stretches without pauses still break at a sentence end.
    static func paragraphs(from tokens: [Token]) -> String {
        var paragraphs: [String] = []
        var current = ""
        for (index, token) in tokens.enumerated() {
            current += token.text
            guard index + 1 < tokens.count else { break }
            let gap = tokens[index + 1].start - token.end
            let sentence = endsSentence(token)
            if gap >= 2.5 || (sentence && (gap >= 1.0 || current.count >= 700)) {
                paragraphs.append(current)
                current = ""
            }
        }
        paragraphs.append(current)
        return paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n") + "\n"
    }

    /// Subtitle cues of at most two lines of about 42 characters and 6 seconds, starting fresh at each
    /// sentence and after each pause.
    static func cues(from tokens: [Token], lineWidth: Int = 42, maxDuration: Double = 6) -> [Cue] {
        var groups: [[Token]] = []
        var current: [Token] = []
        for token in tokens {
            if let last = current.last, let first = current.first {
                let width = self.width(current.map(\.text).joined() + token.text)
                let breaks = endsSentence(last)
                    || token.start - last.end >= 1.0
                    || token.end - first.start > maxDuration
                    || width > 2 * lineWidth
                    || lines(for: current + [token], width: lineWidth).contains { self.width($0) > lineWidth }
                    || (width > lineWidth * 3 / 2 && last.text.trimmingCharacters(in: .whitespaces).last.map { ",;:、，".contains($0) } == true)
                if breaks {
                    groups.append(current)
                    current = []
                }
            }
            current.append(token)
        }
        if !current.isEmpty { groups.append(current) }

        var cues = groups.map { group in
            Cue(start: group.first!.start, end: group.last!.end, lines: lines(for: group, width: lineWidth))
        }
        // Short cues stay up for at least a second (when the next one allows), so they can be read.
        for index in cues.indices {
            let next = index + 1 < cues.count ? cues[index + 1].start : .infinity
            cues[index].end = max(cues[index].end, min(cues[index].start + 1, next))
        }
        return cues
    }

    /// One line, or two of about equal length, broken between words.
    private static func lines(for group: [Token], width lineWidth: Int) -> [String] {
        let full = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard width(full) > lineWidth, group.count > 1 else { return [full] }
        var best = 1, bestWidth = Int.max
        for split in 1..<group.count {
            let first = width(group[..<split].map(\.text).joined()), second = width(group[split...].map(\.text).joined())
            if max(first, second) < bestWidth { bestWidth = max(first, second); best = split }
        }
        return [group[..<best], group[best...]].map { $0.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Characters on screen; Chinese and Japanese characters are about twice as wide as Latin ones.
    private static func width(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).reduce(0) { $0 + (Transcription.isUnspaced($1) ? 2 : 1) }
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(time(cue.start, ",")) --> \(time(cue.end, ","))\n\(cue.lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(time(cue.start, ".")) --> \(time(cue.end, "."))\n\(cue.lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    /// HH:MM:SS,mmm (SRT) or HH:MM:SS.mmm (WebVTT).
    static func time(_ seconds: Double, _ separator: String) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, separator, total % 1000)
    }
}

// MARK: - Subtitle files

/// SRT and WebVTT files: their text without the timings, or the same cues in the other format.
nonisolated enum Subtitles {
    /// Formats that are written directly; other documents (Word, PDF…) are laid out from the plain text.
    static let directTargets = Converter.subtitleTargets

    static func convert(_ request: Converter.Request, output: URL) async throws {
        let data = try Data(contentsOf: request.input)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ConversionError.failed("Couldn't read this subtitle file.")
        }
        let cues = parse(text)
        guard !cues.isEmpty else { throw ConversionError.failed("No subtitles were found in this file.") }
        // Each cue joins the text like a word does, so pauses between cues still start new paragraphs.
        let paragraphs = Transcript.paragraphs(from: cues.map { cue in
            .init(text: cue.lines.joined(separator: " ") + " ", start: cue.start, end: cue.end)
        })
        switch request.to {
        case .srt: try Transcript.srt(cues).write(to: output, atomically: true, encoding: .utf8)
        case .vtt: try Transcript.vtt(cues).write(to: output, atomically: true, encoding: .utf8)
        case .txt, .md: try paragraphs.write(to: output, atomically: true, encoding: .utf8)
        default:
            let text = request.workDir.appending(path: "subtitles.txt")
            try paragraphs.write(to: text, atomically: true, encoding: .utf8)
            let textRequest = Converter.Request(input: text, from: .txt, to: request.to, workDir: request.workDir,
                                            title: request.title, originalDir: request.originalDir, quality: request.quality)
            try await DocumentConversion.convert(textRequest, output: output)
        }
    }

    /// Reads cues from SRT or WebVTT, dropping numbering, styling tags and WebVTT's notes and style blocks.
    static func parse(_ text: String) -> [Transcript.Cue] {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var cues: [Transcript.Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else { continue }
            let body = lines[(timing + 1)...].map(clean).filter { !$0.isEmpty }
            if !body.isEmpty { cues.append(.init(start: start, end: end, lines: body)) }
        }
        return cues
    }

    /// "01:02:03,456", "01:02:03.456" or WebVTT's short "02:03.456".
    private static func seconds(_ text: String) -> Double? {
        let fields = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Removes <i>, <font …>, <v Speaker> and {\an8}-style tags.
    private static func clean(_ line: String) -> String {
        line.replacing(/<[^>]*>/, with: "").replacing(/\{\\[^}]*\}/, with: "").trimmingCharacters(in: .whitespaces)
    }
}
