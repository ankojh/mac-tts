import AVFoundation

/// One audio graph and a bounded queue of in-memory PCM buffers. Sentence and
/// inference boundaries do not tear down the output device or restart playback.
@MainActor
final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var epoch = UUID()
    private var queued = 0
    private var clockBase = 0.0
    private(set) var scheduledEnd = 0.0
    var onDrained: (() -> Void)?
    var rate: Double = 1 {
        didSet { timePitch.rate = Float(min(2, max(1, rate))) }
    }
    var isPlaying: Bool { node.isPlaying && queued > 0 }
    var hasAudio: Bool { queued > 0 }
    var currentTime: Double {
        guard let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) else { return clockBase }
        let heard = Double(time.sampleTime) / time.sampleRate - engine.outputNode.presentationLatency * rate
        return min(scheduledEnd, max(clockBase, clockBase + heard))
    }
    var bufferedDuration: Double { max(0, scheduledEnd - currentTime) }

    init() {
        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    func append(_ chunk: PCMChunk) throws {
        guard let encoded = chunk.pcm, chunk.rate == 24_000,
              let data = Data(base64Encoded: encoded), !data.isEmpty, data.count % 4 == 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 4)),
              let channel = buffer.floatChannelData?[0] else {
            throw HushError(message: "The voice returned invalid PCM audio.")
        }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { UnsafeMutableRawPointer(channel).copyMemory(from: base, byteCount: data.count) }
        }
        if !engine.isRunning { try engine.start() }
        queued += 1
        scheduledEnd += Double(buffer.frameLength) / format.sampleRate
        let token = epoch
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, token == self.epoch else { return }
                self.queued -= 1
                if self.queued == 0 {
                    // Freeze the logical clock during a real underrun. New data
                    // starts a fresh node timeline at the last played sample.
                    self.clockBase = self.scheduledEnd
                    self.node.stop()
                    self.onDrained?()
                }
            }
        }
    }

    func play() { if queued > 0 && !node.isPlaying { node.play() } }
    func pause() { node.pause() }
    func reset() {
        epoch = UUID()
        node.stop()
        queued = 0
        clockBase = 0
        scheduledEnd = 0
    }
    func shutdown() { reset(); engine.stop() }
}
