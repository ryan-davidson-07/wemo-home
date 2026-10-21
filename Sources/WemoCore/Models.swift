import Foundation

public enum BinaryState: Int, Sendable, Equatable {
    case off = 0
    case on = 1

    public var opposite: Self { self == .on ? .off : .on }
    public var title: String { self == .on ? "ON" : "OFF" }
}

/// A manually configured local endpoint. Discovery can supply this same value later.
/// Numeric RFC 1918 IPv4 addresses only; no hostnames, public hosts or URL input.
public struct DeviceEndpoint: Equatable, Sendable {
    public let address: String
    public let port: Int

    public static let rayns = try! DeviceEndpoint(address: "192.168.4.28", port: 49153)

    public init(address: String, port: Int) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, (1...65535).contains(port) else {
            throw WemoError.invalidEndpoint
        }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = Int(part), (0...255).contains(value),
                  String(value) == String(part) else { throw WemoError.invalidEndpoint }
            octets.append(value)
        }
        guard octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168) else {
            throw WemoError.invalidEndpoint
        }
        self.address = address
        self.port = port
    }

    public var displayAddress: String { "\(address):\(port)" }

    func url(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = address
        components.port = port
        components.path = path
        // Initializer validation and fixed internal paths make this URL total.
        return components.url!
    }
}

public struct DeviceDescription: Equatable, Sendable {
    public let friendlyName: String
    public let manufacturer: String
    public let model: String
    public let firmware: String?
}

public struct SOAPFault: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let upnpCode: String?
    public let upnpDescription: String?
}

public enum WemoError: Error, Equatable, Sendable, LocalizedError {
    case invalidEndpoint
    case timedOut
    case unreachable
    case transport(Int)
    case nonHTTPResponse
    case httpStatus(Int)
    case invalidXML
    case invalidResponse(String)
    case soapFault(SOAPFault)
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Enter a private IPv4 address (10.x.x.x, 172.16–31.x.x or 192.168.x.x) and a port from 1 to 65535."
        case .timedOut:
            return "The switch did not respond in time. Check Wi-Fi and the saved address, then refresh."
        case .unreachable:
            return "Cannot reach the switch. Connect to your home Wi-Fi and allow Wemo Home in Settings > Privacy & Security > Local Network."
        case .transport(let code):
            return "The connection failed (network error \(code)). Check Wi-Fi and Local Network permission, then refresh."
        case .nonHTTPResponse:
            return "The switch returned an unsupported network response."
        case .httpStatus(let status):
            return "The switch returned HTTP \(status). Check its address and port."
        case .invalidXML:
            return "The switch returned invalid XML. Refresh to try reading it again."
        case .invalidResponse(let reason):
            return "The switch returned an unexpected response: \(reason)"
        case .soapFault(let fault):
            let detail = fault.upnpDescription ?? fault.message
            let code = fault.upnpCode ?? fault.code
            return "The switch rejected the request (\(code)): \(detail)"
        case .responseTooLarge:
            return "The switch response exceeded the supported size."
        }
    }

    /// A valid HTTP response establishes reachability even when its payload is unusable.
    var establishesReachability: Bool {
        switch self {
        case .httpStatus, .invalidXML, .invalidResponse, .soapFault, .responseTooLarge: return true
        default: return false
        }
    }
}
