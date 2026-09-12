import AppKit
import AVFoundation
import Combine

@MainActor
final class ReaderModel: NSObject, ObservableObject {
    @Published var segments: [ReadingSegment] = []
    @Published var currentIndex = 0
    @Published var source = "Your reading, uninterrupted."
    @Published var status = "Select text anywhere. Press ⌥Space."
    @Published var error: String?
    @Published var voices: [Voice] = []
    @Published var modelReady = false
    @Published var busy = false
    @Published var isPlaying = false
    @Published var wantsPlayback = false
    @Published var progress = 0.0
    @Published var skipped = 0
    @Published var wordCount = 0
    @Published var hasAccessibility = AXIsProcessTrusted()
    @Published var shortcutAvailable = true
    @Published var sourceIsHighlighted = false
    @Published var sourceHighlightChecked = false
    @Published var hasSourceDocument = false
    @Published var isFollowing = false
    @Published var followNewText = UserDefaults.standard.object(forKey: "followNewText") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(followNewText, forKey: "followNewText")
            if !followNewText { endFollowing() }
        }
    }
    @Published var voiceID = UserDefaults.standard.string(forKey: "voice") ?? "af_heart" {
        didSet {
            UserDefaults.standard.set(voiceID, forKey: "voice")
            if oldValue != voiceID { changeVoice() }
        }
    }
    @Published var speed = UserDefaults.standard.object(forKey: "speed") as? Double ?? 1.0 {
        didSet {
            audio.rate = speed
            UserDefaults.standard.set(speed, forKey: "speed")
        }
    }
    @Published var cleanText = UserDefaults.standard.object(forKey: "clean") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cleanText, forKey: "clean") }
    }
    @Published var highlightSource = UserDefaults.standard.object(forKey: "highlight") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(highlightSource, forKey: "highlight")
            updateHighlight()
        }
    }
    private let backend = Backend()
    private let highlighter = SourceHighlighter()
    private let wordHighlighter = SourceHighlighter(isWord: true)
    private struct PlayingWord {
        let segment: Int
        let word: Int
        let start: Double
        let end: Double
    }
    private let audio = PCMStreamPlayer()
    private var playingWords: [PlayingWord] = []
    private var wordCursor = 0
    private var nextSynthesisIndex = 0
    private var document: CapturedDocument?
    private var readingTask: Task<Void, Never>?
    private var generation = UUID()
    private var playbackToken = UUID()
    private var timer: Timer?
    private var lastHighlight = Date.distantPast
    private var lastPermissionCheck = Date.distantPast
    private var followSource: FollowSource?
    private var followTask: Task<Void, Never>?
    private var lastFollowPoll = Date.distantPast
    private var pendingTail = ""
    private var tailChangedAt = Date.distantPast
    private var followFailures = 0
    private var followError: String?
    var targetApp: NSRunningApplication?

    var current: ReadingSegment? { segments.indices.contains(currentIndex) ? segments[currentIndex] : nil }
    var estimatedMinutes: Int { max(1, Int(ceil(Double(wordCount) / (175 * speed)))) }

    override init() {
        super.init()
        speed = min(2, max(1, speed))
        audio.rate = speed
        audio.onDrained = { [weak self] in self?.audioDrained() }
        targetApp = NSWorkspace.shared.frontmostApplication
        highlighter.onAvailability = { [weak self] available in
            if self?.sourceIsHighlighted != available { self?.sourceIsHighlighted = available }
        }
        highlighter.onResolution = { [weak self] _ in self?.sourceHighlightChecked = true }
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await checkBackend() }
    }

    func checkBackend() async {
        do {
            let result = try await backend.request(["op": "status"], as: EngineStatus.self)
            voices = result.voices
            modelReady = result.ready
            if !voices.contains(where: { $0.id == voiceID }) { voiceID = voices.first?.id ?? "af_heart" }
            if !modelReady { error = "Download the local voices by running scripts/setup.sh in the project, then click Retry setup." }
            else {
                error = nil
                _ = try await backend.request(["op": "warmup"], as: WarmupStatus.self)
            }
        } catch { self.error = error.localizedDescription }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        applyAccessibilityStatus(AXIsProcessTrustedWithOptions(options))
        if !hasAccessibility, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        applyAccessibilityStatus(AXIsProcessTrustedWithOptions(options))
    }

    func applyAccessibilityStatus(_ trusted: Bool) {
        hasAccessibility = trusted
        if trusted && error == TextCapture.permissionDeniedMessage { error = nil }
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func capture(selectionOnly: Bool = true) {
        guard let app = targetApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            error = "Switch to an app, select some text, then press ⌥Space."
            return
        }
        stop()
        let token = generation
        busy = true
        status = "Finding your text…"
        error = nil
        let pid = app.processIdentifier
        let name = app.localizedName ?? "Application"
        let follow = followNewText && selectionOnly
        Task {
            do {
                let captured = try await Task.detached(priority: .userInitiated) {
                    try TextCapture.capture(pid: pid, name: name, selectionOnly: selectionOnly, follow: follow)
                }.value
                guard generation == token else { return }
                await load(captured, token: token)
            } catch {
                guard generation == token else { return }
                busy = false
                status = "Ready when you are"
                self.error = error.localizedDescription
            }
        }
    }

    func readClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "The clipboard has no text. Copy a passage first."
            return
        }
        read(text: text, source: "Clipboard")
    }

    func read(text: String, source: String = "Pasted text") {
        stop()
        let token = generation
        Task { await load(CapturedDocument(text: text, source: source, pid: nil, spans: []), token: token) }
    }

    private func load(_ captured: CapturedDocument, token: UUID) async {
        guard generation == token else { return }
        busy = true
        status = "Preparing your reading…"
        error = nil
        do {
            let spokenInput = cleanText ? await Task.detached { TextCapture.speakingText(captured) }.value : captured.text
            guard generation == token else { return }
            let prepared = try await backend.request(["op": "prepare", "text": spokenInput, "clean": cleanText], as: PreparedText.self)
            guard generation == token else { return }
            guard !prepared.segments.isEmpty else { throw HushError(message: "No readable text remains. Turn off Clean reading or select another passage.") }
            document = captured
            followSource = followNewText ? captured.followSource : nil
            isFollowing = followSource != nil
            hasSourceDocument = captured.pid != nil
            source = captured.source
            segments = prepared.segments
            skipped = prepared.skipped
            wordCount = prepared.wordCount
            currentIndex = 0
            busy = false
            wantsPlayback = true
            playCurrent()
        } catch {
            guard generation == token else { return }
            self.error = error.localizedDescription
            busy = false
            status = "Ready when you are"
        }
    }

    func togglePlayback() {
        if wantsPlayback {
            wantsPlayback = false
            audio.pause()
            isPlaying = false
            status = "Paused"
            highlighter.hide(); wordHighlighter.hide()
        } else if audio.hasAudio || readingTask != nil || nextSynthesisIndex < segments.count {
            wantsPlayback = true
            audio.play()
            isPlaying = audio.isPlaying
            status = isPlaying ? "Reading locally" : "Buffering audio…"
            pumpAudio()
        } else if isFollowing {
            wantsPlayback = true
            status = "Waiting for new text…"
            lastFollowPoll = .distantPast
        } else if !segments.isEmpty {
            currentIndex = 0
            wantsPlayback = true
            playCurrent()
        } else {
            capture()
        }
    }

    func stop() {
        endFollowing()
        generation = UUID()
        playbackToken = UUID()
        readingTask?.cancel()
        readingTask = nil
        audio.reset()
        playingWords = []
        wordCursor = 0
        nextSynthesisIndex = 0
        wantsPlayback = false
        isPlaying = false
        busy = false
        progress = 0
        status = "Stopped"
        highlighter.hide(); wordHighlighter.hide()
        backend.cancelStream()
    }

    func clear() {
        stop()
        segments = []
        document = nil
        hasSourceDocument = false
        currentIndex = 0
        source = "Your reading, uninterrupted."
        status = "Select text anywhere. Press ⌥Space."
        error = nil
        skipped = 0
        wordCount = 0
    }

    func move(by delta: Int) {
        guard !segments.isEmpty else { return }
        jump(to: min(max(0, currentIndex + delta), segments.count - 1))
    }

    func jump(to index: Int) {
        guard segments.indices.contains(index) else { return }
        currentIndex = index
        wantsPlayback = true
        playCurrent()
    }

    private func changeVoice() {
        let resume = wantsPlayback
        let waiting = isFollowing && !audio.hasAudio && readingTask == nil && progress >= 1
        let sourceToFollow = followSource
        stop()
        followSource = sourceToFollow
        isFollowing = sourceToFollow != nil
        nextSynthesisIndex = currentIndex
        if waiting {
            nextSynthesisIndex = segments.count
            wantsPlayback = resume
            progress = 1
            status = resume ? "Waiting for new text…" : "Paused"
            return
        }
        if resume && !segments.isEmpty {
            wantsPlayback = true
            playCurrent()
        }
    }

    private func playCurrent() {
        guard current != nil else { return }
        playbackToken = UUID()
        readingTask?.cancel()
        readingTask = nil
        backend.cancelStream()
        audio.reset()
        playingWords = []
        wordCursor = 0
        nextSynthesisIndex = currentIndex
        sourceHighlightChecked = false
        highlighter.hide(); wordHighlighter.hide()
        isPlaying = false
        busy = true
        status = "Preparing voice…"
        error = nil
        progress = Double(currentIndex) / Double(max(1, segments.count))
        pumpAudio()
    }

    private func pumpAudio() {
        guard readingTask == nil, nextSynthesisIndex < segments.count else { return }
        let token = playbackToken
        let voice = voiceID
        readingTask = Task {
            do {
                while nextSynthesisIndex < segments.count {
                    try Task.checkCancellation()
                    guard token == playbackToken else { return }
                    // Roughly twelve seconds of listening reserve, including at
                    // 2x. Pulling the next window supplies explicit backpressure.
                    while audio.bufferedDuration > 12 * speed || !wantsPlayback {
                        try await Task.sleep(for: .milliseconds(100))
                        try Task.checkCancellation()
                        guard token == playbackToken else { return }
                    }
                    var text = ""
                    var bindings: [(segment: Int, word: Int)] = []
                    var end = nextSynthesisIndex
                    while end < segments.count {
                        let segment = segments[end]
                        if !text.isEmpty && text.count + segment.text.count > 1800 { break }
                        if !text.isEmpty { text += " " }
                        text += segment.text
                        for index in (segment.words ?? []).indices { bindings.append((end, index)) }
                        end += 1
                    }
                    let base = audio.scheduledEnd
                    var first = true
                    while true {
                        while audio.bufferedDuration > 12 * speed || !wantsPlayback {
                            try await Task.sleep(for: .milliseconds(100))
                            try Task.checkCancellation()
                        }
                        guard token == playbackToken else { return }
                        let request: [String: Any] = first ? ["op": "stream_start", "text": text, "voice": voice] : ["op": "stream_next"]
                        let chunk = try await backend.request(request, as: PCMChunk.self)
                        try Task.checkCancellation()
                        guard token == playbackToken else { return }
                        first = false
                        for timing in chunk.words ?? [] where bindings.indices.contains(timing.index) {
                            let binding = bindings[timing.index]
                            playingWords.append(PlayingWord(segment: binding.segment, word: binding.word,
                                                            start: base + timing.start, end: base + timing.end))
                        }
                        if chunk.pcm != nil {
                            try audio.append(chunk)
                            busy = false
                            if wantsPlayback { audio.play() }
                            isPlaying = audio.isPlaying
                            status = wantsPlayback ? "Reading locally" : "Paused"
                        }
                        if chunk.done { break }
                    }
                    nextSynthesisIndex = end
                }
                guard token == playbackToken else { return }
                readingTask = nil
                if !audio.hasAudio { audioDrained() }
            } catch {
                guard token == playbackToken, !Task.isCancelled else { return }
                readingTask = nil
                audio.pause()
                busy = false
                isPlaying = false
                wantsPlayback = false
                self.error = error.localizedDescription
                status = "Playback needs attention"
            }
        }
    }

    private func audioDrained() {
        isPlaying = false
        highlighter.hide(); wordHighlighter.hide()
        if readingTask != nil || nextSynthesisIndex < segments.count {
            busy = wantsPlayback
            status = wantsPlayback ? "Buffering audio…" : "Paused"
            pumpAudio()
        } else {
            busy = false
            progress = 1
            if !segments.isEmpty { currentIndex = segments.count - 1 }
            wantsPlayback = isFollowing && wantsPlayback
            status = wantsPlayback ? "Waiting for new text…" : "All caught up"
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastPermissionCheck) > 1 {
            lastPermissionCheck = Date()
            refreshAccessibility()
        }
        isPlaying = audio.isPlaying && wantsPlayback
        updateWordHighlight()
        let followInterval = min(8.0, 0.8 * Double(max(1, followFailures)))
        let queuedText = (document?.text.utf16.count ?? 0) - (current?.end ?? 0)
        if isFollowing, wantsPlayback, followTask == nil, queuedText < 6000,
           Date().timeIntervalSince(lastFollowPoll) >= followInterval {
            pollFollowing()
        }
        if Date().timeIntervalSince(lastHighlight) > 0.6 {
            lastHighlight = Date()
            updateHighlight()
        }
    }

    private func endFollowing() {
        followTask?.cancel()
        followTask = nil
        followSource = nil
        isFollowing = false
        pendingTail = ""
        followFailures = 0
        if let followError, error == followError { error = nil }
        followError = nil
        if !isPlaying && !busy && progress >= 1 {
            wantsPlayback = false
            status = "All caught up"
        }
    }

    private func pollFollowing() {
        guard let sourceToFollow = followSource, let existing = document else { return }
        lastFollowPoll = Date()
        let token = generation
        followTask = Task {
            defer { if generation == token { followTask = nil } }
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try sourceToFollow.snapshot(consumed: existing.text, previousSpans: existing.spans)
                }.value
                guard generation == token, !Task.isCancelled, isFollowing else { return }
                followFailures = 0
                if let followError, error == followError { error = nil }
                followError = nil
                // Refresh AX elements too: streaming renderers often replace nodes.
                document = CapturedDocument(text: existing.text, source: existing.source, pid: existing.pid,
                                            spans: snapshot.mappedSpans)
                let tail = snapshot.tail
                if tail.text != pendingTail {
                    pendingTail = tail.text
                    tailChangedAt = Date()
                }
                guard !tail.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let settled = Date().timeIntervalSince(tailChangedAt) >= 1.6
                let clean = cleanText
                let spoken = clean ? await Task.detached { TextCapture.speakingText(tail) }.value : tail.text
                guard generation == token, !Task.isCancelled, isFollowing else { return }
                let prepared = try await backend.request(["op": "prepare", "text": spoken, "clean": clean], as: PreparedText.self)
                guard generation == token, !Task.isCancelled, isFollowing else { return }
                var ready = prepared.segments
                if !settled {
                    // Hold the unfinished trailing sentence while tokens arrive.
                    // Even terminal punctuation must survive another observation.
                    if !ready.isEmpty { ready.removeLast() }
                }
                let end = settled ? tail.text.utf16.count : (ready.last?.end ?? 0)
                guard end > 0 else { return }
                let appended = TextCapture.slice(tail, range: NSRange(location: 0, length: end))
                let offset = existing.text.utf16.count + 1
                guard offset + end <= TextCapture.maxLength else {
                    endFollowing()
                    error = "This reading reached 100,000 characters. Select a new starting point to continue."
                    return
                }
                let firstNewIndex = segments.count
                let additions = ready.enumerated().map { index, segment in
                    ReadingSegment(id: firstNewIndex + index, text: segment.text, start: offset + segment.start,
                        end: offset + segment.end, kind: segment.kind,
                        words: segment.words?.map { SourceWord(start: offset + $0.start, end: offset + $0.end) })
                }
                let spans = appended.spans.map {
                    SourceSpan(start: offset + $0.start, length: $0.length, element: $0.element,
                               elementOffset: $0.elementOffset, text: $0.text)
                }
                document = CapturedDocument(text: existing.text + "\n" + appended.text, source: existing.source,
                                            pid: existing.pid, spans: snapshot.mappedSpans + spans)
                segments.append(contentsOf: additions)
                wordCount += additions.reduce(0) { $0 + ($1.words?.count ?? $1.text.split(separator: " ").count) }
                pendingTail = ""
                if !additions.isEmpty, wantsPlayback { pumpAudio() }
            } catch {
                guard generation == token, !Task.isCancelled, isFollowing else { return }
                if error is FollowCaptureError {
                    endFollowing()
                    self.error = error.localizedDescription
                    return
                }
                followFailures += 1
                if followFailures >= 3 {
                    let notice = "Waiting to locate the text after your selection. Hush will keep trying; select a new passage if the page changed."
                    followError = notice
                    self.error = notice
                    if !audio.hasAudio && readingTask == nil { status = "Waiting for the original text…" }
                }
            }
        }
    }

    private func updateHighlight() {
        if highlightSource, isPlaying, let current, let document {
            highlighter.show(segment: current, document: document)
        } else { highlighter.hide(); wordHighlighter.hide() }
    }

    private func updateWordHighlight() {
        guard isPlaying, !playingWords.isEmpty else {
            wordHighlighter.hide()
            return
        }
        let time = audio.currentTime + 0.035
        while wordCursor + 1 < playingWords.count, playingWords[wordCursor + 1].start <= time { wordCursor += 1 }
        let spoken = playingWords[wordCursor]
        guard segments.indices.contains(spoken.segment), let words = segments[spoken.segment].words,
              words.indices.contains(spoken.word) else { return }
        if currentIndex != spoken.segment {
            currentIndex = spoken.segment
            sourceHighlightChecked = false
            updateHighlight()
        }
        let current = segments[spoken.segment]
        let fraction = Double(words[spoken.word].end - current.start) / Double(max(1, current.end - current.start))
        progress = min(0.99, (Double(currentIndex) + fraction) / Double(max(1, segments.count)))
        guard highlightSource, let document else { wordHighlighter.hide(); return }
        // Keep the previous/current/next word visible as one moving window.
        // Hold it across short inter-word gaps instead of blinking it off.
        let lower = max(0, spoken.word - 1), upper = min(words.count - 1, spoken.word + 1)
        wordHighlighter.show(segment: ReadingSegment(id: currentIndex * 100_000 + spoken.word, text: "",
                                                     start: words[lower].start, end: words[upper].end,
                                                     kind: "word"), document: document)
    }

    func shutdown() {
        stop()
        timer?.invalidate()
        audio.shutdown()
        backend.reset()
    }
}
