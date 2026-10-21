import Foundation

public enum ConnectionStatus: String, Equatable, Sendable {
    case unknown = "Not checked"
    case checking = "Connecting"
    case online = "Online"
    case offline = "Offline"
}

public struct DeviceSnapshot: Equatable, Sendable {
    public var endpoint: DeviceEndpoint
    public var description: DeviceDescription?
    public var connection: ConnectionStatus = .unknown
    public var light: BinaryState?
    public var isBusy = false
    public var lastUpdated: Date?
    public var errorMessage: String?
}

/// Foundation-only state model, testable on Linux without SwiftUI or Combine.
/// All UI mutations happen on MainActor. One owned operation coalesces refreshes;
/// commands are rejected while busy. Generation checks discard even responses from
/// transports that ignore cancellation. No task survives suspension as a service.
@MainActor
public final class DeviceStore {
    public private(set) var snapshot: DeviceSnapshot {
        didSet { onChange?(snapshot) }
    }
    public var onChange: (@MainActor (DeviceSnapshot) -> Void)?

    private let makeClient: @Sendable (DeviceEndpoint) -> any WemoControlling
    private let pollingSleep: @Sendable (UInt64) async throws -> Void
    private var client: any WemoControlling
    private var operation: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isWriting = false

    public init(endpoint: DeviceEndpoint = .rayns,
                pollingSleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
                makeClient: @escaping @Sendable (DeviceEndpoint) -> any WemoControlling = { WemoClient(endpoint: $0) }) {
        self.makeClient = makeClient
        self.pollingSleep = pollingSleep
        self.client = makeClient(endpoint)
        self.snapshot = DeviceSnapshot(endpoint: endpoint)
    }

    /// Invalidates any previous endpoint's responses, even if its transport ignores cancellation.
    public func configure(_ endpoint: DeviceEndpoint) {
        guard endpoint != snapshot.endpoint else { return }
        cancelOperation()
        client = makeClient(endpoint)
        snapshot = DeviceSnapshot(endpoint: endpoint)
    }

    /// Concurrent refresh callers await the same operation, including a pending command's read-back.
    public func refresh(includeDescription: Bool = false) async {
        if let operation { await operation.value; return }
        let token = generation
        let client = self.client
        let needsDescription = includeDescription || snapshot.description == nil
        snapshot.isBusy = true
        snapshot.errorMessage = nil
        if snapshot.connection != .online { snapshot.connection = .checking }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var description: DeviceDescription?
                if needsDescription { description = try await client.fetchDescription() }
                try Task.checkCancellation()
                guard token == self.generation else { return }
                if let description { self.snapshot.description = description }
                let light = try await client.getState()
                try Task.checkCancellation()
                guard token == self.generation else { return }
                self.accept(light)
            } catch {
                guard token == self.generation else { return }
                self.fail(error, writing: false)
            }
            self.finish(token)
        }
        operation = task
        await task.value
    }

    /// Explicit desired state; never an optimistic toggle or automatically retried write.
    public func setState(_ desired: BinaryState) async {
        guard operation == nil, snapshot.connection == .online, snapshot.light != nil else { return }
        let token = generation
        let client = self.client
        isWriting = true
        snapshot.isBusy = true
        snapshot.light = nil
        snapshot.errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.setState(desired)
                try Task.checkCancellation()
                guard token == self.generation else { return }
                let actual = try await client.getState()
                try Task.checkCancellation()
                guard token == self.generation else { return }
                self.accept(actual)
                if actual != desired {
                    self.snapshot.errorMessage = "Requested \(desired.title), but the switch reports \(actual.title). Refresh to check its current state."
                }
            } catch {
                guard token == self.generation else { return }
                self.fail(error, writing: true)
            }
            self.finish(token)
        }
        operation = task
        await task.value
    }

    /// Called with true only when the device screen is visible and the app is active.
    public func setActive(_ active: Bool, intervalNanoseconds: UInt64 = 15_000_000_000) {
        if !active {
            polling?.cancel()
            polling = nil
            cancelOperation()
            snapshot.light = nil
            snapshot.connection = .unknown
            return
        }
        guard polling == nil else { return }
        let interval = max(intervalNanoseconds, 1_000_000)
        let sleep = pollingSleep
        polling = Task { [weak self] in
            while !Task.isCancelled {
                // Avoid retaining the store through the interval sleep.
                await self?.refresh()
                do { try await sleep(interval) }
                catch { break }
            }
        }
    }

    private func accept(_ state: BinaryState) {
        snapshot.connection = .online
        snapshot.light = state
        snapshot.lastUpdated = Date()
        snapshot.errorMessage = nil
    }

    private func fail(_ error: Error, writing: Bool) {
        snapshot.light = nil
        if error is CancellationError {
            snapshot.connection = .unknown
            snapshot.errorMessage = writing ? "Control was interrupted. The light may have changed. Refresh before trying again." : nil
            return
        }
        snapshot.connection = (error as? WemoError)?.establishesReachability == true ? .online : .offline
        let message = (error as? LocalizedError)?.errorDescription ?? "The switch request failed. Refresh to check the connection."
        snapshot.errorMessage = writing
            ? "The light may have changed; its state could not be confirmed. Refresh before sending another command. \(message)"
            : message
    }

    private func finish(_ token: UInt64) {
        guard token == generation else { return }
        operation = nil
        isWriting = false
        snapshot.isBusy = false
    }

    private func cancelOperation() {
        generation &+= 1
        operation?.cancel()
        operation = nil
        if isWriting {
            snapshot.errorMessage = "Control was interrupted. The light may have changed. Refresh before trying again."
        }
        isWriting = false
        snapshot.isBusy = false
    }

    deinit {
        operation?.cancel()
        polling?.cancel()
    }
}
