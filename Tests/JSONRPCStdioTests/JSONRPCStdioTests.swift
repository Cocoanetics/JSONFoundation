#if os(macOS) || os(Linux)
import Foundation
import JSONFoundation
import JSONRPCStdio
import JSONRPCWire
import Testing

// `cat -u` echoes stdin to stdout verbatim, so a framed message sent out comes
// straight back — proving the Foundation.Process transport round-trips end to end.
@Test(.timeLimit(.minutes(1)))
func processTransportLoopbackThroughCat() async throws {
    let transport = try ProcessTransport(
        launch: ProcessLaunch(executable: "cat", arguments: ["-u"]),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    try transport.send(.request(id: 3, method: "ping", params: .string("hi")))
    let received = try await inbound.next()
    #expect(received?.method == "ping")
    #expect(received?.id == .integer(3))
    transport.close()
}

// A caller-supplied `ProcessLaunch.environment` must reach the child as a full
// replacement (the contract ACP/MCP clients rely on to inject auth vars into the
// agents they spawn) — mirroring the trait-gated Subprocess suite's test so the
// `Foundation.Process` transport's half is verified in a default build too. Spawn
// a shell whose *only* environment variable is `ACP_TEST_VAR` and have it echo
// that value back as a JSON-RPC method name; if the env were dropped (inherited),
// the expansion would be empty.
@Test(.timeLimit(.minutes(1)))
func processTransportChildReceivesCustomEnvironment() async throws {
    let script = #"printf '{"jsonrpc":"2.0","method":"%s","params":null}\n' "$ACP_TEST_VAR""#
    let transport = try ProcessTransport(
        launch: ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: ["ACP_TEST_VAR": "hello-env"]),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    let received = try await inbound.next()
    #expect(received?.method == "hello-env")
    transport.close()
}

// MARK: - Captured stderr

/// The `Foundation.Process` transport keeps the same bounded tail as the subprocess
/// one: a child that dies has usually explained itself on stderr.
/// `waitForExit()` then read — no polling. A child can exit with stderr still queued,
/// so the wait covers the drain as well; otherwise the tail read here could miss the
/// very line that explains the exit.
@Test(.timeLimit(.minutes(1)))
func processTransportCapturesTheStderrTail() async throws {
    let transport = try ProcessTransport(
        launch: ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", "echo 'boom: no such model' >&2; exit 2"],
            stderr: .capture(maxBytes: 4096)),
        framing: LineFraming())

    let exit = await transport.waitForExit()
    #expect(exit.code == 2)
    #expect(transport.capturedStandardError().contains("no such model"))
    transport.close()
}

/// A child that writes a backlog and exits immediately: the final line is the one worth
/// having, and it must survive the exit.
///
/// This pins the contract rather than reproducing the race. `terminationHandler` and the
/// readability drain have no specified ordering, but on macOS the drain wins here — the
/// test passes without the coordination too, even at ~800 KB of backlog. It is kept
/// because the guarantee is what callers rely on, not because it reproduces the failure.
@Test(.timeLimit(.minutes(1)))
func theFinalStderrLineSurvivesAnImmediateExit() async throws {
    let script = "for i in $(seq 1 2000); do echo 'chatter chatter chatter chatter' >&2; done;"
        + " echo 'FINAL: the reason' >&2; exit 7"
    let transport = try ProcessTransport(
        launch: ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", script], stderr: .capture(maxBytes: 512)),
        framing: LineFraming())

    let exit = await transport.waitForExit()
    #expect(exit.code == 7)
    #expect(transport.capturedStandardError().contains("FINAL: the reason"))
    transport.close()
}

@Test(.timeLimit(.minutes(1)))
func processTransportCapturesNothingByDefault() async throws {
    let transport = try ProcessTransport(
        launch: ProcessLaunch(executable: "/bin/sh", arguments: ["-c", "echo noise >&2; cat -u"]),
        framing: LineFraming())
    try transport.send(.request(id: 1, method: "ping", params: nil))
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    _ = try await inbound.next()

    #expect(transport.capturedStandardError().isEmpty)
    transport.close()
}

#endif
