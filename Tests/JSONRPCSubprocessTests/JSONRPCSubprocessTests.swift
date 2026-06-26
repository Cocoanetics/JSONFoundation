// Only meaningful with the `Subprocess` trait enabled; otherwise the module and
// these tests compile to nothing.
#if Subprocess
import Foundation
import JSONFoundation
import Testing
import JSONRPCSubprocess
import JSONRPCWire

@Test(.timeLimit(.minutes(1)))
func stdioMessageTransportLoopbackThroughCat() async throws {
    let transport = StdioMessageTransport(
        endpoint: .childProcess(ProcessLaunch(executable: "cat", arguments: ["-u"])),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    try transport.send(.request(id: 9, method: "documentSymbol", params: nil))
    let received = try await inbound.next()
    #expect(received?.method == "documentSymbol")
    #expect(received?.id == .integer(9))
    transport.close()
}
#endif
