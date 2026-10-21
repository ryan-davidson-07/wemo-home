import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol WemoControlling: Sendable {
    func fetchDescription() async throws -> DeviceDescription
    func getState() async throws -> BinaryState
    func setState(_ state: BinaryState) async throws
}

public struct WemoClient: WemoControlling {
    public let endpoint: DeviceEndpoint
    private let transport: any HTTPTransport

    public init(endpoint: DeviceEndpoint, transport: any HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public func fetchDescription() async throws -> DeviceDescription {
        let request = URLRequest(url: endpoint.url(path: "/setup.xml"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        let response = try await send(request)
        try validate(response)
        return try WemoXML.deviceDescription(response.data)
    }

    public func getState() async throws -> BinaryState {
        let response = try await perform(.getBinaryState)
        guard let state = try WemoXML.binaryState(response.data, action: .getBinaryState) else {
            throw WemoError.invalidResponse("Missing BinaryState.")
        }
        return state
    }

    public func setState(_ state: BinaryState) async throws {
        let response = try await perform(.setBinaryState, state: state)
        _ = try WemoXML.binaryState(response.data, action: .setBinaryState)
    }

    private func perform(_ action: SOAPAction, state: BinaryState? = nil) async throws -> HTTPResponse {
        var request = URLRequest(url: endpoint.url(path: "/upnp/control/basicevent1"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(SOAPEnvelope.service)#\(action.rawValue)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = try SOAPEnvelope.encode(action, state: state)
        let response = try await send(request)
        // SOAP faults commonly arrive with HTTP 500. Preserve their structured details.
        if response.data.count <= 1_048_576, let fault = try? WemoXML.fault(response.data) {
            throw WemoError.soapFault(fault)
        }
        try validate(response)
        return response
    }

    private func validate(_ response: HTTPResponse) throws {
        guard (200...299).contains(response.statusCode) else { throw WemoError.httpStatus(response.statusCode) }
        guard response.data.count <= 1_048_576 else { throw WemoError.responseTooLarge }
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw WemoError.timedOut
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .dataNotAllowed:
                throw WemoError.unreachable
            default: throw WemoError.transport(error.code.rawValue)
            }
        }
    }
}
