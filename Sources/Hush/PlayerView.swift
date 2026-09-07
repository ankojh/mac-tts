import SwiftUI

private let accent = Color(red: 0.56, green: 0.86, blue: 0.71)
private let ink = Color(red: 0.10, green: 0.13, blue: 0.12)

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 420
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PlayerView: View {
    @ObservedObject var model: ReaderModel
    @State private var expanded = false
    @State private var showPaste = false
    @State private var paste = ""
    @State private var permissionHelp = false
    @State private var showTranscript = false
    var hide: () -> Void
    var resize: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                if !model.hasAccessibility && model.segments.isEmpty { permissionCard }
                if let error = model.error { errorCard(error) }
                if showPaste { pasteEditor }
                if model.segments.isEmpty { emptyState }
                else { readingCard }
                controls
                footer
                if expanded { options }
            }
            .padding(20)
        }
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.105, green: 0.12, blue: 0.115))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.10)))
        .preferredColorScheme(.dark)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { height in resize(height) }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(accent)
            Text("hush").font(.system(size: 19, weight: .semibold, design: .rounded))
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(model.modelReady ? accent : Color.orange).frame(width: 5, height: 5)
                Text(model.modelReady ? "ON DEVICE" : "SETUP NEEDED")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.4)
            }.foregroundStyle(.secondary)
            Button(action: hide) { Image(systemName: "minus").frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide player; keep reading")
                .accessibilityLabel("Hide player")
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .background(.white.opacity(0.025))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("A little less screen.\nA little more listening.")
                .font(.system(size: 25, weight: .medium, design: .serif)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Text("Select a passage in an app or browser,\nthen let Hush take it from here.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("⌥").font(.system(size: 13))
                Text("space").font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(accent).padding(.top, 3)
        }.padding(.vertical, 7)
    }

    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.source, systemImage: "doc.text")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(model.currentIndex + 1) / \(model.segments.count)")
                    .monospacedDigit().fixedSize()
                Button { showTranscript.toggle() } label: {
                    Image(systemName: showTranscript ? "chevron.up" : "text.alignleft")
                }.buttonStyle(.plain).help("Show or hide transcript").accessibilityLabel("Toggle transcript")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if model.hasSourceDocument {
                Label(model.sourceIsHighlighted ? "Highlighted in the original text" :
                      model.isPlaying ? (model.sourceHighlightChecked ? "Source text positions are unavailable" : "Locating the original text…") : "Follow along in your app",
                      systemImage: model.sourceIsHighlighted ? "highlighter" : "doc.text.viewfinder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.sourceIsHighlighted ? accent : .secondary)
                    .padding(.vertical, 6)
            }
            if showTranscript || !model.hasSourceDocument {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.segments) { segment in
                            Button { model.jump(to: segment.id) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    if segment.kind == "bullet" { Text("•").foregroundStyle(accent) }
                                    Text(segment.text)
                                        .font(.system(size: 15, weight: segment.id == model.currentIndex ? .medium : .regular))
                                        .lineSpacing(5).multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .foregroundStyle(segment.id == model.currentIndex ? Color.white : Color.white.opacity(0.38))
                                .background(segment.id == model.currentIndex ? accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .leading) {
                                    if segment.id == model.currentIndex { RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 2).padding(.vertical, 9) }
                                }
                            }.buttonStyle(.plain).id(segment.id)
                                .accessibilityLabel("Read sentence \(segment.id + 1): \(segment.text)")
                        }
                    }
                }
                .frame(height: 160)
                .onChange(of: model.currentIndex) { _, index in
                    withAnimation(.easeInOut(duration: 0.22)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(accent).frame(width: geometry.size.width * min(1, max(0, model.progress)))
                }
            }.frame(height: 3)
            HStack {
                Text(model.status)
                Spacer()
                Text("~\(model.estimatedMinutes) min total")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 13) {
            Button { model.move(by: -1) } label: { Image(systemName: "backward.end.fill").frame(width: 22, height: 30) }
                .buttonStyle(.plain).disabled(model.segments.isEmpty || model.currentIndex == 0)
                .help("Previous sentence").accessibilityLabel("Previous sentence")
            Button { model.togglePlayback() } label: {
                ZStack {
                    Circle().fill(accent)
                    if model.busy && model.wantsPlayback { ProgressView().controlSize(.small).tint(ink) }
                    else { Image(systemName: model.wantsPlayback ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink).offset(x: model.wantsPlayback ? 0 : 1) }
                }.frame(width: 48, height: 48)
            }.buttonStyle(.plain).disabled(!model.modelReady || (model.busy && model.segments.isEmpty))
                .help(model.wantsPlayback ? "Pause" : "Read selection / resume")
                .accessibilityLabel(model.wantsPlayback ? "Pause" : "Play")
            Button { model.move(by: 1) } label: { Image(systemName: "forward.end.fill").frame(width: 22, height: 30) }
                .buttonStyle(.plain).disabled(model.segments.isEmpty || model.currentIndex >= model.segments.count - 1)
                .help("Next sentence").accessibilityLabel("Next sentence")
            Spacer(minLength: 5)
            Menu {
                ForEach([1.0, 1.1, 1.25, 1.5], id: \.self) { rate in
                    Button { model.speed = rate } label: {
                        if model.speed == rate { Label(rateLabel(rate), systemImage: "checkmark") }
                        else { Text(rateLabel(rate)) }
                    }
                }
            } label: {
                Text(rateLabel(model.speed)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent).frame(width: 52, height: 32)
                    .background(.white.opacity(0.05), in: Capsule())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Playback speed")
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 25, height: 30)
            }.buttonStyle(.plain).foregroundStyle(expanded ? accent : .secondary)
                .help("Voice and reading options").accessibilityLabel("Reading options")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Read selection  ⌥Space") { model.capture() }
                Button("Read accessible document") { model.capture(selectionOnly: false) }
                Button("Read clipboard  ⌥⇧Space") { model.readClipboard() }
                Button("Paste text…") { showPaste.toggle() }
                Divider()
                Button("Try a sample") { model.read(text: "A quieter way to catch up.\n• Select a passage in your favorite app.\n• Choose a voice, and settle into your own pace.\nYour words stay on this Mac.", source: "Welcome to Hush") }
            } label: {
                Label("Read from", systemImage: "plus").font(.system(size: 11, weight: .medium))
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
            Spacer()
            if !model.segments.isEmpty {
                Button("Clear") { model.clear() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("PRIVATE BY NATURE").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.white.opacity(0.24))
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(.white.opacity(0.03))
            HStack {
                Text("Voice").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("Voice", selection: $model.voiceID) {
                    ForEach(model.voices) { voice in Text("\(voice.name) · \(voice.detail)").tag(voice.id) }
                }.labelsHidden().frame(width: 245)
            }
            Toggle("Clean reading", isOn: $model.cleanText).toggleStyle(.switch).controlSize(.mini)
            Text("Skip common navigation labels, URLs, citations, and code blocks. Applies to your next reading.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, -7)
            Toggle("Highlight in source app", isOn: $model.highlightSource).toggleStyle(.switch).controlSize(.mini)
            Text("Follow sentences and words in apps that expose text positions.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, -7)
            Toggle("Continue and follow new text", isOn: $model.followNewText).toggleStyle(.switch).controlSize(.mini)
            Text("Start with a selection, then keep reading the original document as text arrives. Pause to wait; Clear to stop watching. Applies when you select a new passage.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, -7)
            if model.skipped > 0 { Text("\(model.skipped) non-reading lines skipped").font(.system(size: 10)).foregroundStyle(accent) }
            if !model.shortcutAvailable { Text("⌥Space is in use by another app. Use Read from or change that app's shortcut.").font(.system(size: 10)).foregroundStyle(.orange) }
            HStack {
                Button("Accessibility settings") { model.requestAccessibility() }
                Spacer()
                Button("Quit Hush") { NSApplication.shared.terminate(nil) }
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).tint(accent)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Read across your Mac", systemImage: "hand.raised").font(.system(size: 12, weight: .medium))
            Text("Allow Accessibility to read selected text and highlight it in supported apps. Clipboard reading works without it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Enable Accessibility") { model.requestAccessibility() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
            Button("Already enabled in Settings?") { permissionHelp = true }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .popover(isPresented: $permissionHelp) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Reconnect this copy of Hush").font(.headline)
                        Text("A development rebuild can change the app's identity while its old Accessibility entry still looks enabled.")
                        Text("1. Use Show this app to locate the current copy.\n2. Quit Hush.\n3. In Accessibility settings, remove Hush with −, then add this exact app again with + and enable it.\n4. Reopen Hush.")
                            .lineSpacing(5)
                        HStack {
                            Button("Show this app") { model.revealApp() }
                            Button("Check again") { model.refreshAccessibility(); if model.hasAccessibility { permissionHelp = false } }
                        }
                    }.font(.system(size: 12)).padding(18).frame(width: 330)
                }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(message).font(.system(size: 11)).foregroundStyle(Color.orange.opacity(0.95)).fixedSize(horizontal: false, vertical: true)
            if message == TextCapture.permissionDeniedMessage {
                HStack {
                    Button("Show this app") { model.revealApp() }
                    Button("Check again") { model.refreshAccessibility() }
                }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
            }
            if !model.modelReady { Button("Retry setup") { Task { await model.checkBackend() } }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)) }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var pasteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $paste).font(.system(size: 12)).frame(height: 95)
                .scrollContentBackground(.hidden).padding(8)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Text to read")
            HStack {
                Button("Cancel") { showPaste = false }
                Spacer()
                Button("Read text") { model.read(text: paste); paste = ""; showPaste = false }
                    .disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.system(size: 11))
        }
    }

    private func rateLabel(_ rate: Double) -> String { "\(rate.formatted(.number.precision(.fractionLength(0...2))))×" }
}
