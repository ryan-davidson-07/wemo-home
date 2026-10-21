import Foundation
import Combine
import WemoCore

/// Small Apple UI adapter; networking and state transitions live in the package.
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var snapshot: DeviceSnapshot
    private let store: DeviceStore
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let address = defaults.string(forKey: "device.address") ?? DeviceEndpoint.rayns.address
        let port = defaults.object(forKey: "device.port") as? Int ?? DeviceEndpoint.rayns.port
        let endpoint = (try? DeviceEndpoint(address: address, port: port)) ?? .rayns
        let store = DeviceStore(endpoint: endpoint)
        self.store = store
        self.snapshot = store.snapshot
        store.onChange = { [weak self] in self?.snapshot = $0 }
    }

    func setActive(_ active: Bool) { store.setActive(active) }
    func refresh() async { await store.refresh() }
    func setState(_ state: BinaryState) async { await store.setState(state) }

    func saveAndTest(address: String, port: String) async throws {
        guard let port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WemoError.invalidEndpoint
        }
        let endpoint = try DeviceEndpoint(address: address, port: port)
        store.configure(endpoint)
        defaults.set(endpoint.address, forKey: "device.address")
        defaults.set(endpoint.port, forKey: "device.port")
        await store.refresh(includeDescription: true)
    }
}
