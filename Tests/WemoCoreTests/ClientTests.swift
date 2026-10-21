import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WemoCore

final class ClientTests: XCTestCase {
    func testSetupAndSOAPRequestContract() async throws {
        let transport = MockTransport(Fixtures.initial + [.reply(200, Fixtures.emptySet)])
        let client = WemoClient(endpoint: .rayns, transport: transport)
        let info = try await client.fetchDescription()
        let state = try await client.getState()
        try await client.setState(.on)
        XCTAssertEqual(info.model, "LightSwitch")
        XCTAssertEqual(state, .off)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.absoluteString, "http://192.168.4.28:49153/setup.xml")
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[1].url?.path, "/upnp/control/basicevent1")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "SOAPAction"), "\"urn:Belkin:service:basicevent:1#GetBinaryState\"")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "text/xml; charset=\"utf-8\"")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "SOAPAction"), "\"urn:Belkin:service:basicevent:1#SetBinaryState\"")
        let body = try XCTUnwrap(requests[2].httpBody)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("<BinaryState>1</BinaryState>"))
        XCTAssertEqual(requests[1].timeoutInterval, 5)
    }

    func testHTTPFailuresIncludingRedirectsAreNotSuccess() async {
        for status in [301, 302, 307, 400, 404, 500, 503] {
            let transport = MockTransport([.reply(status, "<html>Error</html>")])
            do {
                _ = try await WemoClient(endpoint: .rayns, transport: transport).getState()
                XCTFail("HTTP failure accepted")
            } catch { XCTAssertEqual(error as? WemoError, .httpStatus(status)) }
            let count = await transport.requestCount
            XCTAssertEqual(count, 1)
        }
    }

    func testFaultOnHTTP500And200() async {
        for status in [500, 200] {
            let transport = MockTransport([.reply(status, Fixtures.fault)])
            do {
                try await WemoClient(endpoint: .rayns, transport: transport).setState(.on)
                XCTFail("Fault accepted")
            } catch {
                guard let wemoError = error as? WemoError, case .soapFault(let fault) = wemoError else { XCTFail("Expected SOAP fault: \(error)"); continue }
                XCTAssertEqual(fault.upnpCode, "501")
            }
        }
    }

    func testTimeoutNeverRetriesWrite() async {
        let transport = MockTransport([.networkError(.timedOut)])
        do {
            try await WemoClient(endpoint: .rayns, transport: transport).setState(.on)
            XCTFail("Timeout accepted")
        } catch { XCTAssertEqual(error as? WemoError, .timedOut) }
        let count = await transport.requestCount
        XCTAssertEqual(count, 1)
    }

    func testOfflineErrors() async {
        for code in [URLError.cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed] {
            let transport = MockTransport([.networkError(code)])
            do {
                _ = try await WemoClient(endpoint: .rayns, transport: transport).getState()
                XCTFail("Offline read accepted")
            } catch { XCTAssertEqual(error as? WemoError, .unreachable) }
        }
    }

    func testInvalidSuccessfulXMLIsAnError() async {
        let transport = MockTransport([.reply(200, "<broken")])
        do {
            _ = try await WemoClient(endpoint: .rayns, transport: transport).getState()
            XCTFail("Malformed XML accepted")
        } catch { XCTAssertEqual(error as? WemoError, .invalidXML) }
    }

    func testSetupStatusIsValidated() async {
        let transport = MockTransport([.reply(404, Fixtures.description)])
        do {
            _ = try await WemoClient(endpoint: .rayns, transport: transport).fetchDescription()
            XCTFail("HTTP error accepted")
        } catch { XCTAssertEqual(error as? WemoError, .httpStatus(404)) }
    }

    func testCancellationRemainsCancellation() async {
        let transport = MockTransport([.networkError(.cancelled)])
        do {
            _ = try await WemoClient(endpoint: .rayns, transport: transport).getState()
            XCTFail("Cancellation accepted")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRejectsNonHTTPTransportResponse() async {
        let transport = MockTransport([.error(.nonHTTPResponse)])
        do {
            _ = try await WemoClient(endpoint: .rayns, transport: transport).getState()
            XCTFail("Non-HTTP response accepted")
        } catch { XCTAssertEqual(error as? WemoError, .nonHTTPResponse) }
    }
}
