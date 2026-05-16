import SwiftUI

struct FakeTunnel: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let state: State

    enum State {
        case running, stopped, failed
    }
}

struct TunnelRowView: View {
    let tunnel: FakeTunnel

    var body: some View {
        HStack(spacing: 10) {
            stateDot
            Text(tunnel.name).font(.body)
            Spacer()
            Button(toggleLabel) {
                // TODO Phase 5 — start/stop via TunnelRunner
            }
            .controlSize(.small)
            Button {
                // TODO Phase 4 — édition
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Éditer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var stateDot: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 9, height: 9)
            .help(stateTooltip)
    }

    private var stateColor: Color {
        switch tunnel.state {
        case .running: .green
        case .stopped: .secondary
        case .failed:  .red
        }
    }

    private var stateTooltip: String {
        switch tunnel.state {
        case .running: "En cours"
        case .stopped: "Arrêté"
        case .failed:  "Échec"
        }
    }

    private var toggleLabel: String {
        switch tunnel.state {
        case .running:           "Stop"
        case .stopped, .failed:  "Start"
        }
    }
}
