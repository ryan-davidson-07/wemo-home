import SwiftUI
import UIKit
import WemoCore

@MainActor
struct HomeView: View {
    @ObservedObject var model: HomeModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    private var screenActive: Bool { scenePhase == .active && !showingSettings }
    private var state: DeviceSnapshot { model.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("A little light. Right at home.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    deviceCard
                    if let error = state.errorMessage { ErrorMessage(message: error) }
                    Label("Controlled over your home Wi-Fi", systemImage: "wifi")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Wemo Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
            .onAppear { model.setActive(screenActive) }
            .onDisappear { model.setActive(false) }
            .onChange(of: screenActive) { _, active in model.setActive(active) }
        }
    }

    private var deviceCard: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rayns").font(.title2.bold())
                    Text("Wemo LightSwitch").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Label(state.connection.rawValue, systemImage: connectionSymbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(state.connection == .online ? Color.accentColor : Color.secondary)
                    .accessibilityLabel("Connection: \(state.connection.rawValue)")
            }
            Button {
                guard let light = state.light else { return }
                Task { await model.setState(light.opposite) }
            } label: {
                VStack(spacing: 12) {
                    Image(systemName: state.light == .on ? "lightbulb.fill" : "lightbulb")
                        .font(.system(size: 64, weight: .light))
                    Text(state.light?.title ?? "Unknown")
                        .font(.largeTitle.bold())
                    Text(state.isBusy ? "Updating…" : controlHint)
                        .font(.subheadline)
                }
                .foregroundStyle(state.light == .on ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding(.vertical, 16)
                .background(state.light == .on ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 24))
                .contentShape(RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy || state.light == nil || state.connection != .online)
            .accessibilityLabel("Rayns light")
            .accessibilityValue(state.isBusy ? "Updating, state unknown" : state.light?.title ?? "Unknown")
            .accessibilityHint(controlHint)

            VStack(spacing: 12) {
                HStack {
                    Text("Light status").foregroundStyle(.secondary)
                    Spacer()
                    Text(state.light.map { $0 == .on ? "On" : "Off" } ?? "Unknown")
                        .fontWeight(.semibold)
                }
                HStack {
                    if state.isBusy { ProgressView().accessibilityLabel("Updating switch") }
                    else if let date = state.lastUpdated {
                        Text("Last read \(date, style: .relative) ago")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .frame(minHeight: 44)
                    }
                    .disabled(state.isBusy)
                }
            }
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
    }

    private var controlHint: String {
        guard let light = state.light else { return "Refresh to check the light" }
        return light == .on ? "Tap to turn off" : "Tap to turn on"
    }

    private var connectionSymbol: String {
        switch state.connection {
        case .online: return "checkmark.circle.fill"
        case .offline: return "wifi.slash"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }
}

@MainActor
struct ErrorMessage: View {
    let message: String

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error. \(message)")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
