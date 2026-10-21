import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WemoCore

final class DeviceStoreTests: XCTestCase {
    @MainActor
    private func makeStore(_ transport: MockTransport) -> DeviceStore {
        DeviceStore(makeClient: { WemoClient(endpoint: $0, transport: transport) })
    }

    @MainActor
    func testStartsUnknownAndRefreshesWithoutWriting() async {
        let transport = MockTransport(Fixtures.initial)
        let store = makeStore(transport)
        XCTAssertNil(store.snapshot.light)
        XCTAssertEqual(store.snapshot.connection, .unknown)
        await store.refresh()
        XCTAssertEqual(store.snapshot.connection, .online)
        XCTAssertEqual(store.snapshot.light, .off)
        XCTAssertEqual(store.snapshot.description?.firmware, "test-firmware")
        XCTAssertNotNil(store.snapshot.lastUpdated)
        XCTAssertFalse(store.snapshot.isBusy)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "SOAPAction")?.contains("SetBinaryState") == true })
    }

    @MainActor
    func testManualRefreshReusesDescription() async {
        let transport = MockTransport(Fixtures.initial + [.reply(200, Fixtures.state("1"))])
        let store = makeStore(transport)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.snapshot.light, .on)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 1)
    }

    @MainActor
    func testOfflineClearsPreviouslyKnownLightAndRecovers() async {
        let transport = MockTransport(Fixtures.initial + [.networkError(.cannotConnectToHost), .reply(200, Fixtures.state("1"))])
        let store = makeStore(transport)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.snapshot.connection, .offline)
        XCTAssertNil(store.snapshot.light)
        XCTAssertNotNil(store.snapshot.errorMessage)
        XCTAssertFalse(store.snapshot.isBusy)
        await store.refresh()
        XCTAssertEqual(store.snapshot.connection, .online)
        XCTAssertEqual(store.snapshot.light, .on)
        XCTAssertNil(store.snapshot.errorMessage)
    }

    @MainActor
    func testHTTPErrorIndicatesReachableButUnknownState() async {
        let transport = MockTransport([.reply(503, "error")])
        let store = makeStore(transport)
        await store.refresh()
        XCTAssertEqual(store.snapshot.connection, .online)
        XCTAssertNil(store.snapshot.light)
        XCTAssertTrue(store.snapshot.errorMessage?.contains("503") == true)
    }

    @MainActor
    func testSetReadsBackActualState() async {
        let transport = MockTransport(Fixtures.initial + [.reply(200, Fixtures.emptySet), .reply(200, Fixtures.state("1"))])
        let store = makeStore(transport)
        await store.refresh()
        await store.setState(.on)
        XCTAssertEqual(store.snapshot.light, .on)
        XCTAssertEqual(store.snapshot.connection, .online)
        XCTAssertNil(store.snapshot.errorMessage)
        let requests = await transport.requests
        XCTAssertTrue(requests[2].value(forHTTPHeaderField: "SOAPAction")?.contains("SetBinaryState") == true)
        XCTAssertTrue(requests[3].value(forHTTPHeaderField: "SOAPAction")?.contains("GetBinaryState") == true)
    }

    @MainActor
    func testAmbiguousWriteFailureDoesNotRetryOrClaimSuccess() async {
        let transport = MockTransport(Fixtures.initial + [.networkError(.timedOut)])
        let store = makeStore(transport)
        await store.refresh()
        await store.setState(.on)
        XCTAssertNil(store.snapshot.light)
        XCTAssertTrue(store.snapshot.errorMessage?.contains("may have changed") == true)
        await store.setState(.on) // Unknown state blocks a second write until a successful refresh.
        let count = await transport.requestCount
        XCTAssertEqual(count, 3)
    }

    @MainActor
    func testReadBackFailureAfterAcknowledgmentIsUnknown() async {
        let transport = MockTransport(Fixtures.initial + [.reply(200, Fixtures.emptySet), .networkError(.timedOut)])
        let store = makeStore(transport)
        await store.refresh()
        await store.setState(.on)
        XCTAssertNil(store.snapshot.light)
        XCTAssertTrue(store.snapshot.errorMessage?.contains("may have changed") == true)
        let count = await transport.requestCount
        XCTAssertEqual(count, 4)
    }

    @MainActor
    func testMismatchUsesActualReadBackWithoutRetry() async {
        let transport = MockTransport(Fixtures.initial + [.reply(200, Fixtures.emptySet), .reply(200, Fixtures.state("0"))])
        let store = makeStore(transport)
        await store.refresh()
        await store.setState(.on)
        XCTAssertEqual(store.snapshot.light, .off)
        XCTAssertTrue(store.snapshot.errorMessage?.contains("switch reports OFF") == true)
        let count = await transport.requestCount
        XCTAssertEqual(count, 4)
    }

    @MainActor
    func testOverlappingRefreshesCoalesce() async {
        let transport = MockTransport([.held, .reply(200, Fixtures.state("1"))])
        let store = makeStore(transport)
        let first = Task { await store.refresh() }
        await waitUntil { await transport.pendingCount == 1 }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await store.refresh()
        }
        await waitUntil { secondStarted }
        XCTAssertTrue(store.snapshot.isBusy)
        await transport.resumeNext(Fixtures.description)
        await first.value
        await second.value
        let count = await transport.requestCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.snapshot.light, .on)
    }

    @MainActor
    func testRefreshDuringWriteWaitsAndSecondWriteIsDropped() async {
        let transport = MockTransport(Fixtures.initial + [.held, .reply(200, Fixtures.state("1"))])
        let store = makeStore(transport)
        await store.refresh()
        let write = Task { await store.setState(.on) }
        await waitUntil { await transport.pendingCount == 1 }
        XCTAssertNil(store.snapshot.light)
        await store.setState(.off)
        var refreshStarted = false
        let refresh = Task {
            refreshStarted = true
            await store.refresh()
        }
        await waitUntil { refreshStarted }
        await transport.resumeNext(Fixtures.emptySet)
        await write.value
        await refresh.value
        XCTAssertEqual(store.snapshot.light, .on)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.filter { $0.value(forHTTPHeaderField: "SOAPAction")?.contains("SetBinaryState") == true }.count, 1)
    }

    @MainActor
    func testEndpointReplacementDiscardsLateResponse() async throws {
        let transport = MockTransport([.held] + Fixtures.initial)
        let store = makeStore(transport)
        let oldRead = Task { await store.refresh() }
        await waitUntil { await transport.pendingCount == 1 }
        let newEndpoint = try DeviceEndpoint(address: "192.168.4.29", port: 49154)
        store.configure(newEndpoint)
        await store.refresh()
        await transport.resumeNext(Fixtures.description.replacingOccurrences(of: "Rayns &amp; Home", with: "Stale device"))
        await oldRead.value
        XCTAssertEqual(store.snapshot.endpoint, newEndpoint)
        XCTAssertEqual(store.snapshot.description?.friendlyName, "Rayns & Home")
        XCTAssertEqual(store.snapshot.light, .off)
        XCTAssertFalse(store.snapshot.isBusy)
        let requests = await transport.requests
        XCTAssertEqual(requests[1].url?.host, "192.168.4.29")
        XCTAssertEqual(requests[1].url?.port, 49154)
    }

    @MainActor
    func testSuspendDiscardsLateReadAndForegroundRefreshes() async {
        let transport = MockTransport([.held] + Fixtures.initial)
        let store = makeStore(transport)
        store.setActive(true, intervalNanoseconds: 60_000_000_000)
        await waitUntil { await transport.pendingCount == 1 }
        store.setActive(false)
        XCTAssertNil(store.snapshot.light)
        XCTAssertEqual(store.snapshot.connection, .unknown)
        store.setActive(true, intervalNanoseconds: 60_000_000_000)
        await waitUntil { store.snapshot.light == .off && !store.snapshot.isBusy }
        await transport.resumeNext(Fixtures.description)
        await Task.yield()
        XCTAssertEqual(store.snapshot.light, .off)
        store.setActive(false)
        XCTAssertNil(store.snapshot.light)
    }

    @MainActor
    func testSuspendedWriteNeverSendsReadBackOrRetry() async {
        let transport = MockTransport(Fixtures.initial + [.held])
        let store = makeStore(transport)
        await store.refresh()
        let write = Task { await store.setState(.on) }
        await waitUntil { await transport.pendingCount == 1 }
        store.setActive(false)
        await transport.resumeNext(Fixtures.emptySet)
        await write.value
        XCTAssertNil(store.snapshot.light)
        XCTAssertTrue(store.snapshot.errorMessage?.contains("may have changed") == true)
        XCTAssertFalse(store.snapshot.isBusy)
        let count = await transport.requestCount
        XCTAssertEqual(count, 3)
    }

    @MainActor
    func testUnknownStateCannotIssueCommand() async {
        let transport = MockTransport([])
        let store = makeStore(transport)
        await store.setState(.on)
        let count = await transport.requestCount
        XCTAssertEqual(count, 0)
    }
    @MainActor
    func testPeriodicRefreshOnlyWhileActive() async {
        let transport = MockTransport(Fixtures.initial + [.reply(200, Fixtures.state("1"))])
        let gate = PollingGate()
        let store = DeviceStore(pollingSleep: { _ in await gate.wait() }) {
            WemoClient(endpoint: $0, transport: transport)
        }
        store.setActive(true)
        store.setActive(true) // Idempotent: do not create a second polling loop.
        await waitUntil { await gate.waitingCount == 1 }
        XCTAssertEqual(store.snapshot.light, .off)
        await gate.advance()
        await waitUntil { await gate.waitingCount == 1 }
        XCTAssertEqual(store.snapshot.light, .on)
        store.setActive(false)
        await gate.advance() // Release the cancelled sleeper without relying on a timer.
        await Task.yield()
        XCTAssertNil(store.snapshot.light)
        let count = await transport.requestCount
        XCTAssertEqual(count, 3)
    }

}
