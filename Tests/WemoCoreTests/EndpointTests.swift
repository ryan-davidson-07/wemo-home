import XCTest
@testable import WemoCore

final class EndpointTests: XCTestCase {
    func testPrivateIPv4Ranges() throws {
        for address in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.4.28"] {
            XCTAssertEqual(try DeviceEndpoint(address: address, port: 49153).address, address)
        }
        XCTAssertEqual(try DeviceEndpoint(address: " 192.168.4.28\n", port: 1).port, 1)
        XCTAssertEqual(try DeviceEndpoint(address: "10.0.0.1", port: 65535).port, 65535)
    }

    func testRejectsPublicAmbiguousAndInvalidAddresses() {
        for address in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "127.0.0.1", "169.254.1.2", "0.0.0.0", "255.255.255.255", "example.com", "http://192.168.4.28", "192.168.4.28:49153", "192.168.04.28", "192.168..28", "192.168.4.256", "192.168.4.-1", "192.168.4.28/path", "::1", "", "192.168.4.28?x"] {
            XCTAssertThrowsError(try DeviceEndpoint(address: address, port: 49153), address)
        }
        for port in [-1, 0, 65536] {
            XCTAssertThrowsError(try DeviceEndpoint(address: "192.168.4.28", port: port))
        }
    }
}
