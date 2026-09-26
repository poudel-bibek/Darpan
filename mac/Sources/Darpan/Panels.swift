import AppKit
import DarpanCore
import SwiftUI

/// What the toolbar panels show, and what they can do. Owned by the session; changes only on
/// events and user actions (never per frame).
final class ViewerModel: ObservableObject {
    @Published var modes: Client.Modes?
    /// Device pixels of the video area, for "Fit this window".
    @Published var windowPixels: CGSize = .zero
    @Published var accessibilityTrusted = KeyboardCapture.accessibilityTrusted

    var setResolution: (DisplayMode?) -> Void = { _ in }     // nil: native
    var sendCombo: ([String]) -> Void = { _ in }
    var setRemoteClipboard: (String) -> Void = { _ in }

    static let combos: [(name: String, codes: [String])] = [
        ("Super", ["MetaLeft"]), ("Alt+Tab", ["AltLeft", "Tab"]), ("Alt+F4", ["AltLeft", "F4"]),
        ("Terminal", ["ControlLeft", "AltLeft", "KeyT"]), ("Ctrl+Alt+Del", ["ControlLeft", "AltLeft", "Delete"]),
        ("PrtSc", ["PrintScreen"]), ("Esc", ["Escape"]), ("Lock", ["MetaLeft", "KeyL"]),
        ("Desk ←", ["ControlLeft", "AltLeft", "ArrowLeft"]), ("Desk →", ["ControlLeft", "AltLeft", "ArrowRight"]),
    ]

    /// Rows of the resolution list: Native, a mode that fills the window, then every mode.
    var resolutionRows: [(title: String, detail: String, mode: DisplayMode?, current: Bool)] {
        guard let m = modes, !m.modes.isEmpty else { return [] }
        var rows: [(String, String, DisplayMode?, Bool)] = [("Native", m.native?.description ?? "", nil, m.current == m.native)]
        if let best = DisplayMode.bestFor(window: windowPixels, among: m.modes), best != m.native {
            rows.append(("Fit this window", best.description, best, false))
        }
        for mode in m.modes where mode != m.native {
            rows.append((mode.description, "", mode, mode == m.current))
        }
        return rows
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct DisplayPanel: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: "Remote resolution") {
                let rows = model.resolutionRows
                if rows.isEmpty {
                    Text("Not available").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(rows.indices, id: \.self) { i in
                                let r = rows[i]
                                Button { model.setResolution(r.mode) } label: {
                                    HStack {
                                        Image(systemName: "checkmark").opacity(r.current ? 1 : 0).font(.system(size: 11, weight: .bold))
                                        Text(r.title)
                                        Spacer()
                                        Text(r.detail).foregroundStyle(.secondary).font(.system(size: 11))
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(RoundedRectangle(cornerRadius: 6).fill(r.current ? Color.primary.opacity(0.12) : .clear))
                            }
                        }
                    }
                    .frame(height: min(196, CGFloat(rows.count) * 28))
                }
            }
            PanelSection(title: "Scaling") {
                Picker("Scaling", selection: $settings.scale) {
                    Text("Fit").tag(ScaleMode.fit)
                    Text("Actual size").tag(ScaleMode.actual)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            PanelSection(title: "Quality") {
                QualityPicker(selection: $settings.quality)
            }
            PanelSection(title: "Frame rate") {
                Picker("Frame rate", selection: $settings.fps) {
                    ForEach(Settings.frameRates, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            PanelSection(title: "Encoding") {
                Toggle("Full GPU on the Linux computer", isOn: $settings.fullGPU)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Text("Sharpest and fastest video, using about 250 MB of the Linux computer’s GPU memory while you’re connected. Off: about 40 MB.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct KeysPanel: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelSection(title: "Send keys") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(ViewerModel.combos, id: \.name) { c in
                        Button { model.sendCombo(c.codes) } label: { Text(c.name).frame(maxWidth: .infinity) }
                    }
                }
            }
            PanelSection(title: "⌘ Command sends") {
                Picker("⌘ Command sends", selection: $settings.command) {
                    Text("Ctrl").tag(CommandKey.ctrl)
                    Text("Super").tag(CommandKey.super)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            PanelSection(title: "System shortcuts") {
                Toggle("Send ⌘Tab, ⌘Space, Mission Control… too", isOn: $settings.captureSystemKeys)
                if settings.captureSystemKeys && !model.accessibilityTrusted {
                    Text("Allow Darpan in System Settings → Privacy & Security → Accessibility.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Text("⌃⌥⌘D disconnects, ⌃⌥⌘F toggles full screen, ⌃⌥⌘⎋ releases the keyboard.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            PanelSection(title: "Scrolling") {
                HStack {
                    Slider(value: $settings.scrollSpeed, in: 0.25...3, step: 0.25).accessibilityLabel("Scroll speed")
                    Toggle("Reverse", isOn: $settings.invertScroll)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Four quality choices as a segmented row; the long names take two lines ("Faster" over "Speed").
private struct QualityPicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Settings.qualities, id: \.kbps) { q in
                let on = selection == q.kbps
                Button { selection = q.kbps } label: {
                    Text(q.name.replacingOccurrences(of: " ", with: "\n"))
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : Color.clear))
                .help("Up to \(q.kbps / 1000) Mbit/s; less when the network needs it")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
    }
}
