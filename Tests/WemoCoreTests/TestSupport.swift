import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WemoCore

/// No URLSession is instantiated by these tests. Held steps intentionally ignore
/// cancellation, allowing tests to prove that late responses cannot corrupt state.
actor MockTransport: HTTPTransport {
    enum Step: Sendable {
        case reply(Int, String)
        case networkError(URLError.Code)
        case error(WemoError)
        case held
    }

    private var steps: [Step]
    private var captured: [URLRequest] = []
    private var pending: [CheckedContinuation<HTTPResponse, Error>] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        captured.append(request)
        guard !steps.isEmpty else { throw WemoError.invalidResponse("Mock response queue exhausted.") }
        switch steps.removeFirst() {
        case .reply(let status, let xml): return HTTPResponse(data: Data(xml.utf8), statusCode: status)
        case .networkError(let code): throw URLError(code)
        case .error(let error): throw error
        case .held:
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
    }

    func resumeNext(_ xml: String, status: Int = 200) {
        precondition(!pending.isEmpty)
        pending.removeFirst().resume(returning: HTTPResponse(data: Data(xml.utf8), statusCode: status))
    }

    var requests: [URLRequest] { captured }
    var requestCount: Int { captured.count }
    var pendingCount: Int { pending.count }
}

enum Fixtures {
    static func envelope(_ content: String, prefix: String = "s") -> String {
        "<\(prefix):Envelope xmlns:\(prefix)=\"http://schemas.xmlsoap.org/soap/envelope/\"><\(prefix):Body>\(content)</\(prefix):Body></\(prefix):Envelope>"
    }

    static func state(_ value: String, action: String = "GetBinaryState") -> String {
        envelope("<u:\(action)Response xmlns:u=\"urn:Belkin:service:basicevent:1\"><BinaryState>\(value)</BinaryState></u:\(action)Response>")
    }

    static let emptySet = envelope("<u:SetBinaryStateResponse xmlns:u=\"urn:Belkin:service:basicevent:1\"/>")
    static let fault = envelope("""
    <s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
    <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>501</errorCode>
    <errorDescription>Action Failed</errorDescription></UPnPError></detail></s:Fault>
    """)
    static let description = """
    <?xml version="1.0"?>
    <root xmlns="urn:Belkin:device-1-0"><device>
    <deviceType>urn:Belkin:device:lightswitch:1</deviceType>
    <friendlyName>Rayns &amp; Home</friendlyName><manufacturer>Belkin International Inc.</manufacturer>
    <modelName>LightSwitch</modelName><firmwareVersion>test-firmware</firmwareVersion>
    <serviceList><service><serviceType>urn:Belkin:service:basicevent:1</serviceType>
    <controlURL>/upnp/control/basicevent1</controlURL></service></serviceList>
    </device></root>
    """
    static let initial: [MockTransport.Step] = [.reply(200, description), .reply(200, state("0"))]
}

@MainActor
func waitUntil(file: StaticString = #filePath, line: UInt = #line,
               _ predicate: @MainActor () async -> Bool) async {
    // Cooperative scheduling only: no wall-clock timing assumption or real networking.
    for _ in 0..<10_000 {
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("Condition was not reached", file: file, line: line)
}

actor PollingGate {
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { pending.append($0) } }
    var waitingCount: Int { pending.count }
    func advance() { precondition(!pending.isEmpty); pending.removeFirst().resume() }
}
