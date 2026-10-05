import Foundation

/// Output of a finished command-line process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a command-line tool to completion, capturing its output, with a timeout.
public enum ProcessRunner {
    /// Blocking: call off the main thread.
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        // No stdin: some tools wait for piped input otherwise.
        process.standardInput = FileHandle.nullDevice

        let stdout = OutputCollector()
        let stderr = OutputCollector()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        // Read continuously so a chatty process never blocks on a full pipe. Start before launching
        // so the end of a process that exits immediately isn't missed.
        stdout.start()
        stderr.start()
        do {
            try process.run()
        } catch {
            stdout.stop()
            stderr.stop()
            throw error
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // Stop the whole process group so helpers it started can't keep the pipes open.
            signal(process, SIGTERM)
            if exited.wait(timeout: .now() + 2) == .timedOut {
                signal(process, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }

        // A helper the process left running can hold the pipes open; don't wait on it for long.
        let deadline = DispatchTime.now() + (timedOut ? 1 : 5)
        return ProcessResult(
            // Reading the status of a process Foundation still considers running would trap.
            status: process.isRunning ? -1 : process.terminationStatus,
            stdout: stdout.finish(deadline: deadline),
            stderr: stderr.finish(deadline: deadline),
            timedOut: timedOut
        )
    }
}

/// Signals the process and, when it leads its own process group (as launched processes do),
/// everything in that group.
private func signal(_ process: Process, _ signal: Int32) {
    let pid = process.processIdentifier
    guard pid > 0 else { return }
    if getpgid(pid) == pid {
        kill(-pid, signal)
    } else {
        kill(pid, signal)
    }
}

/// Collects everything written to a pipe, reading on its own thread so a chatty process never
/// blocks on a full pipe.
private final class OutputCollector: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()
    private let reachedEnd = DispatchSemaphore(value: 0)

    func start() {
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread { [self] in
            while true {
                // Blocks until data arrives; empty means every writer has closed the pipe.
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
            reachedEnd.signal()
        }
    }

    /// Ends reading when the process never started.
    func stop() {
        try? pipe.fileHandleForWriting.close()
    }

    /// Waits until the end of the output or the deadline, whichever comes first.
    func finish(deadline: DispatchTime) -> Data {
        _ = reachedEnd.wait(timeout: deadline)
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
