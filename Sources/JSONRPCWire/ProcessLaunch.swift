import Foundation

/// How to launch a child process that speaks JSON-RPC over stdio.
///
/// A generic, transport-agnostic launch descriptor shared by every stdio
/// consumer (LSP, ACP, MCP). Not tied to any one process API — `Foundation.Process`
/// and `swift-subprocess` both consume it. It lives in `JSONRPCWire` because that
/// is the shared, dependency-free module both stdio transports (`JSONRPCStdio` and
/// `JSONRPCSubprocess`) already import — it is a launch *description*, not I/O.
public struct ProcessLaunch: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var workingDirectory: String?
    /// What becomes of the child's stderr — its own logs, never part of the JSON-RPC
    /// stdout stream either way.
    public var stderr: StderrDisposition

    /// The two-way view this type had before ``StderrDisposition`` existed: reads as
    /// `true` only for ``StderrDisposition/inherit``, and writing it selects `inherit`
    /// or `discard`.
    public var inheritStderr: Bool {
        get { stderr == .inherit }
        set { stderr = newValue ? .inherit : .discard }
    }

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        stderr: StderrDisposition = .discard
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stderr = stderr
    }

    /// Convenience for the pre-``StderrDisposition`` spelling.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        inheritStderr: Bool
    ) {
        self.init(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory, stderr: inheritStderr ? .inherit : .discard)
    }
}

/// What a stdio transport does with its child's stderr.
public enum StderrDisposition: Sendable, Equatable {
    /// Passes through to this process's stderr — the child's logs appear in ours.
    case inherit
    /// Dropped.
    case discard
    /// Kept, but only the last `maxBytes`, and still drained: a child whose stderr is
    /// never read can block on a full pipe or die of `EPIPE`, so the bytes past the
    /// limit are read and thrown away rather than left unread.
    ///
    /// For diagnosing a child that dies: whatever it said on the way out is what
    /// explains the exit, and the tail is where that lives. Read it back with the
    /// transport's `capturedStandardError()`.
    case capture(maxBytes: Int)
}

/// The last `maxBytes` of a stream, kept across concurrent appends.
///
/// Internal to the package's transports; exposed to callers as a `String` through
/// their `capturedStandardError()`.
package final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let maxBytes: Int

    package init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    package func append(_ chunk: Data) {
        guard maxBytes > 0, !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        bytes.append(chunk)
        if bytes.count > maxBytes { bytes.removeFirst(bytes.count - maxBytes) }
    }

    /// The tail as text. A cut may land mid-character, so decoding is lossy rather
    /// than failing — a diagnostic string is worth more than nothing.
    package var text: String {
        lock.lock()
        defer { lock.unlock() }
        // Deliberately lossy: keeping a *tail* means the first bytes may be half a
        // character, and a diagnostic string with one replacement character is worth
        // more than no diagnostic at all — which is what the failable initializer
        // would give here.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }
}
