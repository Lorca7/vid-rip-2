import Foundation

/// Outcome of running a command-line tool.
struct ProcessResult {
    let status: Int32
    let lines: [String]

    var succeeded: Bool { status == 0 }

    /// The most useful lines to show a person when the tool failed.
    var errorSummary: String {
        let errorLines = lines.filter { $0.contains("ERROR") || $0.localizedCaseInsensitiveContains("error") }
        let picked = errorLines.isEmpty ? Array(lines.suffix(6)) : Array(errorLines.suffix(4))
        let text = picked.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The tool exited with status \(status)." : text
    }
}

/// Thread-safe ring buffer of the most recent output lines.
final class LineBuffer: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int = 300) { self.limit = limit }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Runs bundled tools (yt-dlp, ffmpeg) and streams their output line by line.
enum ProcessRunner {
    /// Tracks running tools so they can be stopped when the app quits.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [ObjectIdentifier: Process] = [:]

        func add(_ process: Process) {
            lock.lock(); processes[ObjectIdentifier(process)] = process; lock.unlock()
        }

        func remove(_ process: Process) {
            lock.lock(); processes[ObjectIdentifier(process)] = nil; lock.unlock()
        }

        var all: [Process] {
            lock.lock(); defer { lock.unlock() }
            return Array(processes.values)
        }
    }

    private static let registry = Registry()

    /// Stops every tool that is still running (used when the app quits).
    static func terminateAll() {
        for process in registry.all where process.isRunning {
            process.terminate()
        }
    }

    /// Runs `executable` with `arguments`. Every line written to stdout or stderr
    /// (split on newlines and carriage returns) is passed to `onLine` on a background thread.
    /// Cancelling the calling task terminates the process and throws `CancellationError`.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        qualityOfService: QualityOfService = .default,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ToolBox.shared.environment
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = qualityOfService
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffer = LineBuffer()
        let exitStatus = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }

        try process.run()
        registry.add(process)
        defer { registry.remove(process) }

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for handle in [outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
                    group.addTask {
                        do {
                            for try await line in handle.bytes.lines {
                                buffer.append(line)
                                onLine(line)
                            }
                        } catch {
                            // The pipe closed; nothing more to read.
                        }
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        var status: Int32 = -1
        for await value in exitStatus { status = value }

        if Task.isCancelled { throw CancellationError() }
        return ProcessResult(status: status, lines: buffer.all)
    }
}
