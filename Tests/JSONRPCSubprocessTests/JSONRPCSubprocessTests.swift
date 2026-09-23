// Only meaningful with the `Subprocess` trait enabled; otherwise the module and
// these tests compile to nothing.
#if Subprocess
import Foundation
import JSONFoundation
import JSONRPCSubprocess
import JSONRPCWire
import Testing

@Test(.timeLimit(.minutes(1)))
func stdioMessageTransportLoopbackThroughCat() async throws {
    let transport = StdioTransport(
        endpoint: .childProcess(ProcessLaunch(executable: "cat", arguments: ["-u"])),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    try transport.send(.request(id: 9, method: "documentSymbol", params: nil))
    let received = try await inbound.next()
    #expect(received?.method == "documentSymbol")
    #expect(received?.id == .integer(9))
    transport.close()
}

// A caller-supplied `ProcessLaunch.environment` must reach the child as a full
// replacement (the contract the `Foundation.Process` transport already honors, and
// the one ACP/MCP clients rely on to inject auth vars into spawned agents). Spawn a
// shell whose *only* environment variable is `ACP_TEST_VAR` and have it echo that
// value back as a JSON-RPC method name; if the env were dropped (`.inherit`), the
// expansion would be empty.
@Test(.timeLimit(.minutes(1)))
func childProcessReceivesCustomEnvironment() async throws {
    let script = #"printf '{"jsonrpc":"2.0","method":"%s","params":null}\n' "$ACP_TEST_VAR""#
    let transport = StdioTransport(
        endpoint: .childProcess(ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: ["ACP_TEST_VAR": "hello-env"])),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    let received = try await inbound.next()
    #expect(received?.method == "hello-env")
    transport.close()
}
#endif

// MARK: - Captured stderr

/// A child that dies has usually said why on stderr. `.capture` keeps the tail of it
/// so the caller can quote that instead of reporting a bare exit.
@Test(.timeLimit(.minutes(1)))
func capturedStderrExplainsAChildThatDies() async throws {
    let script = "echo 'agent failed: missing credentials' >&2; exit 1"
    let transport = StdioTransport(
        endpoint: .childProcess(ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", script],
            stderr: .capture(maxBytes: 4096))),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    // The child writes no JSON-RPC, so the stream ends; the stderr tail is the story.
    _ = try? await inbound.next()
    for _ in 0 ..< 50 where transport.capturedStandardError().isEmpty {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    #expect(transport.capturedStandardError().contains("missing credentials"))
    transport.close()
}

/// Only the tail is kept — the point is a bounded buffer, not a transcript.
@Test(.timeLimit(.minutes(1)))
func capturedStderrKeepsOnlyTheTail() async throws {
    // 400 lines of padding, then the line that matters.
    let script = "for i in $(seq 1 400); do echo 'pad pad pad pad pad' >&2; done;"
        + " echo 'LAST LINE' >&2; exit 3"
    let transport = StdioTransport(
        endpoint: .childProcess(ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", script],
            stderr: .capture(maxBytes: 256))),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    _ = try? await inbound.next()
    for _ in 0 ..< 50 where !transport.capturedStandardError().contains("LAST LINE") {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    let captured = transport.capturedStandardError()
    #expect(captured.contains("LAST LINE"))
    #expect(captured.utf8.count <= 256)
    transport.close()
}

/// The default disposition captures nothing, so nothing changes for callers that
/// never ask for it.
@Test(.timeLimit(.minutes(1)))
func stderrIsNotCapturedByDefault() async throws {
    let transport = StdioTransport(
        endpoint: .childProcess(ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", "echo noise >&2; cat -u"])),
        framing: LineFraming())
    try transport.send(.request(id: 1, method: "ping", params: nil))
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    _ = try await inbound.next()

    #expect(transport.capturedStandardError().isEmpty)
    transport.close()
}

/// A child whose stderr is never drained can stall on a full pipe; `.capture` keeps
/// reading past the limit, so a chatty child still gets through its work.
@Test(.timeLimit(.minutes(1)))
func aChattyChildIsNotStalledByTheLimit() async throws {
    let script = "for i in $(seq 1 2000); do echo 'noisy diagnostic line' >&2; done;"
        + #" printf '{"jsonrpc":"2.0","method":"survived","params":null}\n'"#
    let transport = StdioTransport(
        endpoint: .childProcess(ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", script],
            stderr: .capture(maxBytes: 64))),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    let received = try await inbound.next()

    #expect(received?.method == "survived")
    transport.close()
}
