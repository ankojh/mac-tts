import AppKit
import AVFoundation
import Combine

@MainActor
final class ReaderModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
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
            player?.rate = Float(speed)
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
    private var wordTimings: [WordTiming] = []
    private var document: CapturedDocument?
    private var player: AVAudioPlayer?
    private var clips: [Int: Task<AudioClip, Error>] = [:]
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
    var targetApp: NSRunningApplication?

    var current: ReadingSegment? { segments.indices.contains(currentIndex) ? segments[currentIndex] : nil }
    var estimatedMinutes: Int { max(1, Int(ceil(Double(wordCount) / (175 * speed)))) }

    override init() {
        super.init()
        speed = min(1.5, max(1, speed))
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
            else { error = nil }
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
            player?.pause()
            isPlaying = false
            status = "Paused"
            highlighter.hide(); wordHighlighter.hide()
        } else if let player, player.currentTime < player.duration - 0.05 {
            wantsPlayback = true
            isPlaying = player.play()
            status = "Reading locally"
            updateHighlight()
        } else if isFollowing, !busy, progress >= 1 {
            wantsPlayback = true
            if currentIndex + 1 < segments.count {
                currentIndex += 1
                playCurrent()
            } else {
                status = "Waiting for new text…"
                lastFollowPoll = .distantPast
            }
        } else if !segments.isEmpty {
            if progress >= 1 { currentIndex = 0 }
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
        clips.values.forEach { $0.cancel() }
        clips.removeAll()
        player?.stop()
        player = nil
        wantsPlayback = false
        isPlaying = false
        busy = false
        progress = 0
        status = "Stopped"
        highlighter.hide(); wordHighlighter.hide()
        // Kill pending synthesis so an old document never delays a new selection.
        backend.reset()
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
        let waiting = isFollowing && player == nil && progress >= 1
        let sourceToFollow = followSource
        stop()
        followSource = sourceToFollow
        isFollowing = sourceToFollow != nil
        if waiting {
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

    private func clip(at index: Int) -> Task<AudioClip, Error> {
        if let existing = clips[index] { return existing }
        let text = segments[index].text
        let voice = voiceID
        let task = Task { try await backend.request(["op": "synthesize", "text": text, "voice": voice], as: AudioClip.self) }
        clips[index] = task
        return task
    }

    private func playCurrent() {
        guard current != nil else { return }
        sourceHighlightChecked = false
        wordTimings = []
        wordHighlighter.hide()
        let index = currentIndex
        let token = UUID()
        playbackToken = token
        readingTask?.cancel()
        player?.stop()
        player = nil
        isPlaying = false
        highlighter.hide(); wordHighlighter.hide()
        progress = Double(index) / Double(max(1, segments.count))
        busy = true
        status = "Preparing voice…"
        error = nil
        let nextClip = clip(at: index)
        readingTask = Task {
            do {
                let audio = try await nextClip.value
                guard playbackToken == token, !Task.isCancelled else { return }
                guard let data = Data(base64Encoded: audio.audio) else { throw HushError(message: "The voice returned invalid audio.") }
                let nextPlayer = try AVAudioPlayer(data: data)
                nextPlayer.enableRate = true
                nextPlayer.rate = Float(speed)
                nextPlayer.delegate = self
                nextPlayer.prepareToPlay()
                player = nextPlayer
                wordTimings = audio.words ?? []
                busy = false
                if wantsPlayback {
                    guard nextPlayer.play() else { throw HushError(message: "Could not start audio. Check your Mac's sound output.") }
                    isPlaying = true
                    status = "Reading locally"
                    updateHighlight()
                } else { status = "Paused" }
                // Keep only the current and following sentence's audio in memory.
                clips = clips.filter { $0.key == index || $0.key == index + 1 }
                if segments.indices.contains(index + 1) { _ = clip(at: index + 1) }
            } catch {
                guard playbackToken == token, !Task.isCancelled else { return }
                clips.removeValue(forKey: index)
                self.error = error.localizedDescription
                busy = false
                wantsPlayback = false
                isPlaying = false
                status = "Playback needs attention"
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            isPlaying = false
            guard flag else {
                wantsPlayback = false
                error = "Audio playback was interrupted. Press play to retry this sentence."
                highlighter.hide(); wordHighlighter.hide()
                return
            }
            if currentIndex + 1 < segments.count, wantsPlayback {
                currentIndex += 1
                playCurrent()
            } else {
                wantsPlayback = isFollowing
                progress = 1
                status = isFollowing ? "Waiting for new text…" : "All caught up"
                highlighter.hide(); wordHighlighter.hide()
                clips.removeAll()
            }
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastPermissionCheck) > 1 {
            lastPermissionCheck = Date()
            refreshAccessibility()
        }
        if let player, isPlaying, !segments.isEmpty {
            progress = (Double(currentIndex) + player.currentTime / max(0.01, player.duration)) / Double(segments.count)
        }
        updateWordHighlight()
        if isFollowing, wantsPlayback, followTask == nil, Date().timeIntervalSince(lastFollowPoll) >= 0.8 {
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
                    try sourceToFollow.snapshot(consumed: existing.text)
                }.value
                guard generation == token, !Task.isCancelled, isFollowing else { return }
                followFailures = 0
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
                if !additions.isEmpty, wantsPlayback, player == nil, !busy {
                    currentIndex = firstNewIndex
                    playCurrent()
                } else if !additions.isEmpty, segments.indices.contains(currentIndex + 1) {
                    _ = clip(at: currentIndex + 1)
                }
            } catch {
                guard generation == token, !Task.isCancelled, isFollowing else { return }
                followFailures += 1
                if followFailures >= 3 {
                    endFollowing()
                    self.error = error.localizedDescription
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
        guard highlightSource, isPlaying, let player, let current, let document,
              let timing = wordTimings.first(where: { player.currentTime >= $0.start && player.currentTime < $0.end }),
              let words = current.words, words.indices.contains(timing.index) else {
            wordHighlighter.hide()
            return
        }
        let word = words[timing.index]
        // Re-query while a word is active so scrolling and app switches are followed.
        wordHighlighter.show(segment: ReadingSegment(id: timing.index, text: "", start: word.start,
                                                     end: word.end, kind: "word"), document: document)
    }

    func shutdown() {
        stop()
        timer?.invalidate()
    }
}
