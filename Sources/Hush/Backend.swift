import Foundation

struct Voice: Codable, Identifiable {
    let id: String
    let name: String
    let detail: String
    let lang: String
}

struct ReadingSegment: Codable, Identifiable {
    let id: Int
    let text: String
    let start: Int
    let end: Int
    let kind: String
    var words: [SourceWord]? = nil
}

struct SourceWord: Codable {
    let start: Int
    let end: Int
}

struct WordTiming: Decodable {
    let index: Int
    let start: Double
    let end: Double
}

struct PreparedText: Codable {
    let segments: [ReadingSegment]
    let skipped: Int
    let wordCount: Int
    enum CodingKeys: String, CodingKey {
        case segments, skipped
        case wordCount = "word_count"
    }
}

struct EngineStatus: Decodable {
    let ready: Bool
    let voices: [Voice]
    let engine: String
}

struct AudioClip: Decodable {
    let audio: String
    let duration: Double
    let elapsed: Double
    let words: [WordTiming]?
}

struct HushError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class Backend {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]

    private func start() throws {
        if process?.isRunning == true { return }
        if process != nil { reset(HushError(message: "Speech worker stopped. Please retry.")) }
        let info = Bundle.main.infoDictionary ?? [:]
        let environment = ProcessInfo.processInfo.environment
        let root = environment["HUSH_PROJECT_ROOT"] ?? FileManager.default.currentDirectoryPath
        let python = environment["HUSH_PYTHON"] ?? info["HushPython"] as? String ?? root + "/.venv/bin/python"
        let packagedWorker = Bundle.main.resourceURL?.appendingPathComponent("worker/HushWorker").path
        let worker = packagedWorker.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        let bundledModels = Bundle.main.resourceURL?.appendingPathComponent("models").path
        let modelPath = environment["HUSH_MODEL_DIR"] ?? (worker != nil ? bundledModels : nil) ?? info["HushModelDirectory"] as? String ?? root + "/.runtime/models"
        let bundledBackend = Bundle.main.resourceURL?.appendingPathComponent("backend").path
        let backendPath = bundledBackend.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? root + "/backend"
        guard worker != nil || FileManager.default.isExecutableFile(atPath: python) else {
            throw HushError(message: "Python environment is missing. Run scripts/setup.sh, then scripts/build.sh in the project.")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: worker ?? python)
        task.arguments = worker == nil ? ["-u", "-m", "hush_tts.worker"] : []
        task.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        var env = environment
        env["PYTHONPATH"] = backendPath
        env["HUSH_MODEL_DIR"] = modelPath
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        task.environment = env
        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        // No persisted text or diagnostic logs.
        task.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let bytes = handle.availableData
            Task { @MainActor in
                guard let task, self?.process === task else { return }
                self?.receive(bytes)
            }
        }
        task.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard self?.process === ended else { return }
                self?.reset(HushError(message: "Speech worker stopped. Press play to restart it."))
            }
        }
        try task.run()
        process = task
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    func request<T: Decodable>(_ payload: [String: Any], as type: T.Type) async throws -> T {
        try Task.checkCancellation()
        try start()
        let id = UUID().uuidString
        var body = payload
        body["id"] = id
        var bytes = try JSONSerialization.data(withJSONObject: body)
        bytes.append(10)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                guard self?.pending[id] != nil else { return }
                self?.reset(HushError(message: "Speech took too long. Try a shorter passage or restart playback."))
            }
            do { try input?.write(contentsOf: bytes) }
            catch { reset(error) }
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func receive(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        buffer.append(bytes)
        guard buffer.count < 40_000_000 else {
            reset(HushError(message: "The speech worker returned too much data."))
            return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            do {
                guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = reply["id"] as? String,
                      let continuation = pending.removeValue(forKey: id) else { continue }
                timeouts.removeValue(forKey: id)?.cancel()
                if reply["ok"] as? Bool == true, let result = reply["result"] {
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: result))
                } else {
                    continuation.resume(throwing: HushError(message: reply["error"] as? String ?? "Speech failed."))
                }
            } catch {
                reset(HushError(message: "Could not read the speech worker response."))
                return
            }
        }
    }

    func reset(_ error: Error = CancellationError()) {
        let old = process
        process = nil
        output?.readabilityHandler = nil
        output = nil
        try? input?.close()
        input = nil
        if old?.isRunning == true { old?.terminate() }
        buffer.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0.resume(throwing: error) }
    }
}
