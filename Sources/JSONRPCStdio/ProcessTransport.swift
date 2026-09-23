// `Foundation.Process` exists on macOS / Linux / Windows, not on iOS-family OSes.
#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire

/// How the child process ended, as reported by ``ProcessTransport/waitForExit()``.
public struct ProcessExit: Sendable {
    /// The child's termination status (exit code, or signal number for
    /// `.uncaughtSignal`).
    public var code: Int32

    /// Whether the child exited normally or was killed by an uncaught signal.
    public var reason: Process.TerminationReason

    public init(code: Int32, reason: Process.TerminationReason) {
        self.code = code
        self.reason = reason
    }
}

/// How long ``ProcessTransport/waitForExit()`` waits for a captured stderr to reach EOF
/// once the child has exited. EOF normally lands immediately, but it is not guaranteed to
/// arrive at all — a grandchild that inherited stderr holds the write end open — so the
/// wait is bounded rather than indefinite.
private let stderrDrainGrace: DispatchTimeInterval = .milliseconds(250)

/// Errors specific to launching the `Foundation.Process` transport.
public enum ProcessTransportError: Error, LocalizedError {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): return "Failed to launch process: \(reason)"
        }
    }
}

/// A ``JSONRPCMessageTransport`` backed by `Foundation.Process` — the
/// zero-dependency stdio transport, always available (no `Subprocess` trait).
/// Ships in the `JSONRPCStdio` module/product.
///
/// It shares the framing layer with ``StdioTransport`` (it's generic over
/// `MessageFraming` too); only the process/IO mechanics differ. A dedicated reader
/// thread and two `NSLock`s bridge Foundation's blocking reads and its
/// `terminationHandler` callback — the very machinery the `swift-subprocess`-based
/// ``StdioTransport`` (module `JSONRPCSubprocess`, trait `Subprocess`) removes.
/// Prefer that one for cross-platform, lock-free I/O; this one needs no dependency.
public final class ProcessTransport<Framing: MessageFraming>: JSONRPCMessageTransport, @unchecked Sendable {
    private let framing: Framing
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrTail: StderrTail?
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false
    private var exitResult: ProcessExit?
    private var exitWaiters: [CheckedContinuation<ProcessExit, Never>] = []
    /// Set while a captured stderr is still being drained. The child can exit with bytes
    /// left queued in the pipe, so exit alone does not mean the tail is complete —
    /// `waitForExit()` waits for both, and a caller can read the final diagnostic
    /// straight after it returns.
    private var awaitingStderrEOF = false
    /// The read end of a captured stderr pipe, kept so ``close()`` can cancel its
    /// readability source: a handler left installed outlives the transport, and on Linux
    /// keeps the whole process from exiting.
    private var stderrReadHandle: FileHandle?

    /// The child's process identifier (pid), valid once launched.
    public var processIdentifier: Int32 { process.processIdentifier }

    /// The tail of the child's stderr kept under ``StderrDisposition/capture(maxBytes:)``,
    /// as text. Empty for any other disposition, and for a child that wrote nothing.
    public func capturedStandardError() -> String {
        stderrTail?.text ?? ""
    }

    public init(launch: ProcessLaunch, framing: Framing) throws {
        self.framing = framing
        if case .capture(let maxBytes) = launch.stderr {
            self.stderrTail = StderrTail(maxBytes: maxBytes)
        } else {
            self.stderrTail = nil
        }
        process.executableURL = Self.resolveExecutable(launch.executable)
        process.arguments = launch.arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        attachStandardError(launch.stderr, to: process)
        if let env = launch.environment {
            process.environment = env
        }
        if let cwd = launch.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let result = ProcessExit(code: proc.terminationStatus, reason: proc.terminationReason)
            self.stateLock.lock()
            self.exitResult = result
            // Bytes can still be queued in a captured stderr pipe: hold the waiters
            // until its EOF arrives so the tail they read is the child's last word.
            let awaitingDrain = self.awaitingStderrEOF
            let waiters = awaitingDrain ? [] : self.exitWaiters
            if !awaitingDrain { self.exitWaiters = [] }
            self.stateLock.unlock()
            for waiter in waiters { waiter.resume(returning: result) }
            guard awaitingDrain else { return }
            // Wait briefly for the tail to complete, then release regardless. A tail
            // missing its last bytes is a far better failure than a caller that never
            // wakes — which is exactly what an indefinite wait produced on Linux, where
            // a child that writes once and exits never delivered the empty read.
            DispatchQueue.global().asyncAfter(deadline: .now() + stderrDrainGrace) { [weak self] in
                self?.finishStderrDrain()
            }
        }

        do {
            try process.run()
        } catch {
            throw ProcessTransportError.launchFailed("\(launch.executable): \(error.localizedDescription)")
        }
    }

    /// Point the child's stderr at whatever the disposition asks for.
    ///
    /// Under `.capture` the pipe is read continuously rather than at exit: one nobody
    /// reads fills up and stalls the child. Only the tail is kept, and EOF on it is what
    /// tells ``waitForExit()`` the tail is final.
    private func attachStandardError(_ disposition: StderrDisposition, to process: Process) {
        switch disposition {
        case .inherit:
            process.standardError = FileHandle.standardError
        case .discard:
            process.standardError = nil
        case .capture:
            let pipe = Pipe()
            process.standardError = pipe
            let tail = stderrTail
            awaitingStderrEOF = true
            stderrReadHandle = pipe.fileHandleForReading
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard chunk.isEmpty else {
                    tail?.append(chunk)
                    return
                }
                handle.readabilityHandler = nil
                self?.finishStderrDrain()
            }
        }
    }

    /// Called on stderr EOF: the tail is complete, so an exit that already happened can
    /// now be reported.
    private func finishStderrDrain() {
        stateLock.lock()
        awaitingStderrEOF = false
        let result = exitResult
        let waiters = result == nil ? [] : exitWaiters
        if result != nil { exitWaiters = [] }
        stateLock.unlock()
        if let result { for waiter in waiters { waiter.resume(returning: result) } }
    }

    /// Suspends until the child exits, returning its termination status.
    ///
    /// Under ``StderrDisposition/capture(maxBytes:)`` this also waits for the stderr
    /// pipe to reach EOF, so ``capturedStandardError()`` read straight afterwards
    /// includes whatever the child said last — which is usually the part that explains
    /// the exit.
    public func waitForExit() async -> ProcessExit {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if let result = exitResult, !awaitingStderrEOF {
                stateLock.unlock()
                continuation.resume(returning: result)
            } else {
                exitWaiters.append(continuation)
                stateLock.unlock()
            }
        }
    }

    public func send(_ message: JSONRPCMessage) throws {
        let framed = framing.frame(try message.encoded())
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { throw JSONRPCPeerError.closed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: framed)
    }

    public func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, any Error> {
        let framing = self.framing
        return AsyncThrowingStream { continuation in
            let handle = stdoutPipe.fileHandleForReading
            startFramedReaderThread(
                name: "jsonrpc.process.reader",
                framing: framing,
                readChunk: { handle.availableData }, // empty on EOF: child closed stdout
                onBody: { body in
                    for message in (try? JSONRPCMessage.decodeMessages(from: body)) ?? [] {
                        continuation.yield(message)
                    }
                },
                onEOF: { continuation.finish() })

            continuation.onTermination = { [weak self] _ in
                self?.close()
            }
        }
    }

    public func close() {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()

        try? stdinPipe.fileHandleForWriting.close()
        // Leaving a readability handler installed keeps its dispatch source — and on
        // Linux the whole process — alive after the transport is done with.
        if let handle = stderrReadHandle {
            handle.readabilityHandler = nil
            try? handle.close()
            stderrReadHandle = nil
        }
        finishStderrDrain()
        if process.isRunning {
            process.terminate()
        }
    }

    private static func resolveExecutable(_ command: String) -> URL {
        // Platform conventions differ: Windows separates PATH entries with ";"
        // (a ":" split would shred drive-letter paths like C:\Windows), accepts
        // both slash styles and drive-prefixed commands, and finds executables
        // by extension.
        #if os(Windows)
        let isExplicitPath = command.contains("\\") || command.contains("/")
            || command.dropFirst().first == ":"
        let listSeparator: Character = ";"
        let defaultPath = ""
        let suffixes = ["", ".exe", ".cmd", ".bat"]
        #else
        let isExplicitPath = command.contains("/")
        let listSeparator: Character = ":"
        let defaultPath = "/usr/bin:/bin"
        let suffixes = [""]
        #endif

        if isExplicitPath {
            return URL(fileURLWithPath: command)
        }
        #if os(Windows)
        // Windows environment names are case-insensitive and the variable is
        // conventionally spelled `Path`; Foundation's dictionary lookup is
        // case-sensitive, so match by folded key.
        let path = ProcessInfo.processInfo.environment
            .first { $0.key.uppercased() == "PATH" }?.value ?? defaultPath
        #else
        let path = ProcessInfo.processInfo.environment["PATH"] ?? defaultPath
        #endif
        for directory in path.split(separator: listSeparator) where !directory.isEmpty {
            for suffix in suffixes {
                let candidate = URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(command + suffix)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return URL(fileURLWithPath: command)
    }
}

#endif
