# Hush

A small, floating macOS reader. SwiftUI and AppKit in front, Python and a local Kokoro model behind it.

## Start on this Mac

The standalone app is installed at **`/Applications/Hush.app`**. Open **Hush** from Applications or Spotlight (or run `./scripts/run.sh`). It includes its own Python runtime and model files and does not need this project folder or a separate Python installation to run. Hush has a Dock icon and a standard **Hush → Quit Hush** menu (**Command–Q**).

1. Click **Enable Accessibility** in Hush and enable **Hush** in System Settings → Privacy & Security → Accessibility. If it is not listed, use **+** and select `/Applications/Hush.app`. You can skip this and use clipboard/pasted text.
2. Switch to an app or browser, select a passage, and press **Option–Space**.
3. Choose a voice under the sliders button, or change speed using the **1×** control.

**Continue and follow new text** is enabled by default in Reading options. Select your starting passage and press Option–Space: Hush reads the selection, continues through the original document or response, then displays **Waiting for new text…** and resumes as more text appears. Pause suspends following; **Clear** stops watching. Turn the option off before a new reading to read only the selection.

Following stays attached to the original accessible document's main content. It skips editable chat composers and does not switch to whatever tab you open next. It queues completed chunks while text grows and releases the trailing fragment after it has settled for roughly 1.6 seconds. It continues from the last verified text position in sections of at most 6,000 characters, rather than requiring the whole page to fit in a snapshot. Temporary capture failures are retried with a visible notice; a unique recent text context can recover a replaced text node. If the document closes/navigates or the reading reaches the 100,000-character limit, select a fresh starting point. Apps must expose incoming text through Accessibility; clipboard/pasted text cannot be followed.

| Control | Action |
| --- | --- |
| Option–Space | Read the current app's selected text |
| Option–Shift–Space | Read clipboard text |
| Control–Option–Space | Pause / resume |
| Previous / next | Move one sentence |
| Click a sentence | Read from that sentence |
| Read from menu | Selection, accessible document, clipboard, paste, or sample |
| Minus button | Hide the player while reading continues |
| Menu bar waveform | Show / hide the player; right-click for stop and quit |
| Clear | Stop and discard the current reading |

Speed choices are **1×, 1.1×, 1.25×, 1.5×, 1.75×, and 2×**, applied immediately through the native audio graph. Voice changes restart the current sentence. Voice, speed, and cleanup preferences persist; reading text and generated audio do not.

## Install from a fresh checkout

Requirements: Apple Silicon Mac, macOS 14+, Xcode command-line tools with Swift 5.9+, and Python 3.11–3.13. This checkout was built with Swift 6.3.3 and Python 3.12.

```bash
./scripts/setup.sh
./scripts/build.sh
open dist/Hush.app
```

`setup.sh` installs pinned Python dependencies in `.venv` and downloads approximately **142 MB** of model/voice files into `.runtime/models`. The downloader checks SHA-256 hashes and replaces incomplete downloads atomically. After setup, speech runs without internet. ONNX Runtime telemetry is explicitly disabled.

Set `HUSH_PYTHON` to choose the Python interpreter during setup. Set `HUSH_MODEL_DIR` during setup **and build** to use a different model directory. `HUSH_PROJECT_ROOT`, `HUSH_PYTHON`, and `HUSH_MODEL_DIR` can also override runtime paths when launching the executable directly.

The default `build.sh` output is a development app using this checkout's Python environment. To build and install the standalone version (about 266 MB):

```bash
.venv/bin/python -m pip install -r backend/packaging-requirements.txt
./scripts/install.sh
```

Standalone builds freeze the Python worker with PyInstaller and embed the verified model files. To verify the packaged worker independently of the project and system Python:

```bash
.venv/bin/python scripts/check-packaged-worker.py /Applications/Hush.app/Contents/Resources/worker/HushWorker /Applications/Hush.app/Contents/Resources/models
```

The app is signed for local use and is not notarized for distribution to other Macs. Rebuilding with an ad-hoc signature changes its identity; reinstall only after quitting Hush and then reauthorize if required. Installed copies are not modified by ordinary development builds. Use a code-signing certificate below for a stable identity across updates.

### Accessibility is enabled, but Hush says access is denied

The enabled entry can belong to an earlier development build. Ad-hoc signatures identify a specific binary hash, so rebuilding can invalidate the previous grant even though the switch still looks enabled. Hush checks actual macOS authorization, not the switch's visual state.

1. Quit Hush completely using **Reading options → Quit Hush**.
2. Open **System Settings → Privacy & Security → Accessibility**.
3. Select the Hush entry and remove it with **−**.
4. Use **+** to add **`/Applications/Hush.app`**, then enable it. In the file picker, **Command–Shift–G** lets you enter the full app path.
5. Reopen Hush and try Option–Space again.

Hush's **Already enabled in Settings?** help and **Show this app** button locate the actual running bundle. **Check again** refreshes authorization without another prompt, and the old permission error clears when access is granted. Hush never resets or edits the macOS permission database itself.

For development builds that retain the same signing identity, use an existing code-signing certificate:

```bash
HUSH_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build.sh
```

Switching from the ad-hoc identity to a certificate still requires re-adding Hush once. Subsequent builds must use that same identity. Without a certificate, the script retains ad-hoc signing and prints the reauthorization instructions. See [Apple's explanation of code identity and permission matching](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/).

## Reading and highlighting

- **Selected text is the default.** This gives you control over the passage and avoids page furniture.
- **Read accessible document** attempts to collect the focused document or browser's accessible text, excluding toolbars, buttons, and navigation landmarks. It is a bounded best-effort accessibility traversal, not a guaranteed full-page/article extractor. Virtualized pages may expose only loaded content.
- **Clipboard and paste** work in apps that do not expose their selections. Hush reads the clipboard only when requested and does not send Copy keystrokes or overwrite it.
- **Clean reading** handles Markdown headings, ordered/unordered/task lists, emphasis, link labels, numeric citations, soft-wrapped paragraphs, and simple pipe tables. Table cells are spoken left to right with pauses. It filters a conservative list of standalone navigation labels, raw URLs, decorative emoji, separators, and fenced code blocks. It does not summarize, reorder, or deduplicate prose.
- Turn cleanup off before reading to retain code blocks, URLs, and labels that might be meaningful in your document. Formatting punctuation is still normalized. This is deterministic cleanup, not semantic noise detection; inspect the transcript if exact wording matters.
- Source highlighting follows the current sentence/chunk, with a stronger orange **three-word moving window** covering the previous, current, and next word. It stays visible between words, keeps its old position until new bounds arrive, and animates movement along a line. Model-derived timings follow the audio graph's playback position, including pauses and speed changes.
- Alignment maps contextual phonemes back to written words, including multiword pronunciations of numbers. When a pronunciation cannot be matched, the word window holds until the next mapped word. These are model timings, not hand-corrected speech alignments.
- With **Clean reading** enabled, Hush skips numeric bracket citations, Markdown footnote markers/definitions, Unicode superscript/subscript digits, dagger annotations, and raised/lowered text when the source app exposes that formatting through Accessibility. Plain clipboard text cannot reveal formatting that was lost during copying. This also removes numeric exponents/subscripts in formulas; disable cleanup when those are meaningful.
- Browser selections are mapped across accessible text leaves, including bold text, links, and bullets. Hush verifies that the captured text is unchanged, refreshes the line positions while playing, and hides highlights when paused or when you switch to another app. Using Hush's controls keeps the source highlights visible. It does not modify your selection or scroll your document.
- Version 0.5 prefers browser text leaves over page-level numeric ranges (which can provide text without bounds), retries unique mappings when marker endpoints identify containers, and supports verified browser text-marker bounds when numeric bounds are missing.
- The transcript is collapsed by default for source reading. Use the transcript button to expand it. Clipboard and pasted text keep the transcript visible because they have no source position.
- Source highlighting depends on app support for accessibility ranges and bounds; some browsers, PDFs, canvas editors, remote desktops, and protected fields cannot provide these. Hush reports when source positions are unavailable, and the optional transcript remains available. No OCR or browser extension is installed.
- The first release offers six **English** voices: Heart, Bella, Nicole, Michael, Emma, and George. It does not automatically detect language. Images, complex mathematical notation, and arbitrary tables are not interpreted.

## Local model choice

[Kokoro 82M](https://huggingface.co/hexgrad/Kokoro-82M) is a compact Apache-2.0 TTS model. Hush uses the [maintainer's ONNX conversion](https://github.com/thewh1teagle/kokoro-onnx) through `kokoro-onnx==0.6.1`, with the [v1.1 release's INT8 export and voice bank](https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.1). The download hashes are pinned in `backend/hush_tts/models.py` because release assets can change.

ONNX CPU inference avoids loading PyTorch or a multi-billion-parameter model. Hush warms the model on launch and keeps it loaded between readings, using four CPU inference threads. Stop cancels the active stream after its current inference window; quitting Hush releases the worker and model.

The production playback path sends **24 kHz float PCM chunks** directly from Python to an `AVAudioPlayerNode` queue, with `AVAudioUnitTimePitch` controlling speed. No sentence WAV is created in this path and no speech is written to disk. Several sentences are phonemized together, then synthesized in short overlapping windows with context on either side and 10 ms crossfades. The app pulls more chunks while playing, targeting roughly twelve seconds of listening reserve; it stops requesting chunks when paused or when the queue is full.

Kokoro's ONNX graph must finish one short inference window before emitting its audio; it is not sample-by-sample autoregressive generation. First-chunk latency and possible underruns at high speeds still depend on this Mac's inference performance. Version 0.6 has not been benchmarked or listening-tested. The old `synthesize` operation remains for the development tools and returns an in-memory WAV; the app uses the new PCM streaming operations.

Document capture joins inline links and styled text inside their paragraph instead of making each leaf a speech fragment. Citation cleanup also recognizes numeric bracket references split across lines/zero-width characters, Wikipedia citation-link targets, and browser superscript/subscript style groups.

Initial measurements on this Apple Silicon Mac, September 6, 2026, using a short passage per voice: **1.64 seconds model load**, **0.41–0.55 real-time factor**, and **584 MB peak Python RSS**. With word alignment in version 0.4, the standalone worker generated the first test clip in **5.43 seconds** including startup; subsequent voices generated **2.85–4.30 seconds** of speech in **1.43–1.87 seconds**. These short-passage observations are not guarantees for every text or system load.

Version 0.4 passes 34 automated tests and packaged audio/timestamp checks for all six voices. Annotation cleanup was also verified through the installed app's native playback flow. Live word-overlay verification in native editors and browsers still needs a manual check on your preferred apps.

Version 0.5 was compiled and packaged without writing or running tests, as requested. Streaming follow and the browser-bound changes are ready for user testing.

Version 0.6 was likewise compiled and packaged without new tests, test runs, benchmarks, or live playback checks, per the user's request.

Version 0.6.1 updates continuation to use verified source cursors, bounded lookahead, document-wide scope, and retries for temporary capture failures. It was compiled and packaged without tests or playback checks.

## Development and verification

```bash
./scripts/test.sh           # Python cleanup/protocol tests + Swift subprocess integration tests
./scripts/test.sh --audio   # also synthesize and validate audio from all six real voices
./scripts/build.sh         # release executable and dist/Hush.app
```

No Swift package dependencies are required. `Package.swift` can be opened in Xcode. To run outside the bundle, launch from the project root or set `HUSH_PROJECT_ROOT`.

| Location | Responsibility |
| --- | --- |
| `Sources/Hush/App.swift` | App lifecycle, menu bar, floating panel, Carbon global shortcuts |
| `Sources/Hush/PlayerView.swift` | Native player and reading options |
| `Sources/Hush/ReaderModel.swift` | Playback, prefetch, cancellation, reading state |
| `Sources/Hush/TextCapture.swift` | AX capture and browser text marker handling |
| `Sources/Hush/SourceTextMapper.swift` | UTF-16 source mapping across formatted text leaves |
| `Sources/Hush/SourceHighlighter.swift` | Verified source bounds and click-through line overlays |
| `Sources/Hush/FollowSource.swift` | Original-document snapshots, continuation anchoring, and source remapping |
| `Sources/Hush/Backend.swift` | Private JSON-lines subprocess transport, errors and restart |
| `Sources/Hush/PCMStreamPlayer.swift` | Continuous PCM buffer scheduling, playback clock, and 1–2× speed |
| `backend/hush_tts/text.py` | Cleanup and bounded sentence segmentation with source offsets |
| `backend/hush_tts/engine.py` | Model lifecycle and in-memory PCM/WAV synthesis |
| `backend/hush_tts/streaming.py` | Incremental context windows, PCM chunks, crossfades, and word timing |
| `backend/hush_tts/models.py` | Explicit download and checksum validation |
| `backend/hush_tts/worker.py` | Request validation and protocol dispatch |

The worker supports `status`, `warmup`, `prepare`, `stream_start`, `stream_next`, `stream_cancel`, and legacy `synthesize`, with a caller-provided request `id`. There is no HTTP endpoint, listening port, cloud TTS fallback, analytics, reading history, or persisted speech. Standard output carries JSON only; library diagnostics are discarded by the native app. Input is capped at 100,000 characters, source segments at 1,000 characters, and streaming requests at 4,000 characters. Actual model inference windows remain below the model's phoneme-token limit.

Manual checks for your preferred apps: select text containing emoji and bullets; use Option–Space; verify the passage and source highlight; pause/resume and change speed; scroll and switch apps; then try clipboard mode. Password fields should be rejected. A missing source highlight should not prevent playback.
