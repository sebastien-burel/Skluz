import SwiftUI
import AppKit

struct LogViewerView: View {
    let tunnel: Tunnel
    let viewModel: TunnelsViewModel

    @State private var lines: [String] = []
    @State private var autoScroll = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logBody
            Divider()
            footer
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 400)
        .task(id: tunnel.id) {
            while !Task.isCancelled {
                lines = await viewModel.logLines(for: tunnel.id)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Logs — \(tunnel.name)").font(.headline)
                Text("\(lines.count) ligne\(lines.count > 1 ? "s" : "") (stderr ssh)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Suivre", isOn: $autoScroll)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var logBody: some View {
        if lines.isEmpty {
            VStack(spacing: 6) {
                Text("Aucun log").font(.headline)
                Text("Les lignes stderr de ssh apparaîtront ici une fois le tunnel démarré.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onChange(of: lines.count) { _, _ in
                    if autoScroll, let last = lines.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Effacer", role: .destructive) {
                Task {
                    await viewModel.clearLogs(for: tunnel.id)
                    lines = []
                }
            }
            .disabled(lines.isEmpty)

            Button("Copier") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(lines.joined(separator: "\n"), forType: .string)
            }
            .disabled(lines.isEmpty)

            Spacer()
            Button("Fermer") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    LogViewerView(
        tunnel: Tunnel(name: "ComfyUI", type: .localForward, sshHost: "dgx.haruni.net",
                       localPort: 8188, remoteHost: "localhost", remotePort: 8188),
        viewModel: TunnelsViewModel(
            store: TunnelStore(),
            runner: TunnelRunner(logStore: LogStore()),
            configParser: SSHConfigParser(),
            logStore: LogStore()
        )
    )
}
