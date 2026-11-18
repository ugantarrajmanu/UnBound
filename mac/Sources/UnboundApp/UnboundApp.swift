import AppKit
import SwiftUI
import UnboundHostCore

@main
struct UnboundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.isConnected ? "rectangle.on.rectangle.angled.fill" : "rectangle.on.rectangle.angled")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy only: a second launch just hands over to the running one.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me }) {
            NSApp.terminate(nil)
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.hasScreenRecording || !model.hasAccessibility { permissions }
            Divider()
            display
            Divider()
            connections
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unbound").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(model.statusLine).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let s = model.stats {
                    Text(String(format: "%.0f fps · %.1f Mbps", s.encodeFPS, s.mbps))
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("", isOn: $model.enabled).toggleStyle(.switch).labelsHidden()
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .connected: .green
        case .waiting, .starting: .orange
        case .failed: .red
        case .off: .gray
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.hasScreenRecording {
                PermissionRow(title: "Screen Recording", detail: "Needed to show the display on your tablet.",
                              action: "Grant", perform: model.requestScreenRecording)
                Button("Already granted? Relaunch Unbound", action: model.relaunch)
                    .buttonStyle(.link).font(.caption)
            }
            if !model.hasAccessibility {
                PermissionRow(title: "Accessibility", detail: "Lets touch and keyboard on the tablet control your Mac.",
                              action: "Grant", perform: model.requestAccessibility)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Display").font(.subheadline.weight(.semibold))
            Picker("Resolution", selection: $model.presetID) {
                ForEach(DisplayPreset.all) { Text($0.title).tag($0.id) }
            }
            Picker("Frame rate", selection: $model.fps) {
                Text("60 Hz").tag(60)
                Text("90 Hz").tag(90)
                Text("120 Hz").tag(120)
            }
            .pickerStyle(.segmented)
            Text("Arrange it in System Settings › Displays.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connections").font(.subheadline.weight(.semibold))
            Label("USB-C — plug in the tablet", systemImage: "cable.connector").font(.callout)
            Toggle("Wi-Fi (asks before a new tablet connects)", isOn: $model.wifi)
            Toggle("Developer USB (adb)", isOn: $model.developerUSB)
                .help("For tablets with USB debugging enabled. Not needed for normal use.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Open at login", isOn: $model.launchAtLogin)
            HStack {
                Button("Get the tablet app…", action: model.openDownloadPage).buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action, action: perform)
        }
    }
}
