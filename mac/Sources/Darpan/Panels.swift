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
    /// The scale a fit is drawn at now (the viewer's choice, or by this Mac's screen).
    @Published var fitScale = 200
    /// The latest `stream`, and the host's bitrate target to 0.1 Mbit/s: what the display panel says is in effect.
    @Published var stream: Client.StreamInfo?
    @Published var targetKbps: Double?
    /// The host's last notice, e.g. why More GPU or full colour went.
    @Published var notice: String?

    var setResolution: (DisplayMode?) -> Void = { _ in }     // nil: native
    var fitThisWindow: () -> Void = {}
    var setFitScale: (Int) -> Void = { _ in }
    var sendCombo: ([String]) -> Void = { _ in }
    var setRemoteClipboard: (String) -> Void = { _ in }

    static let combos: [(name: String, codes: [String])] = [
        ("Super", ["MetaLeft"]), ("Alt+Tab", ["AltLeft", "Tab"]), ("Alt+F4", ["AltLeft", "F4"]),
        ("Terminal", ["ControlLeft", "AltLeft", "KeyT"]), ("Ctrl+Alt+Del", ["ControlLeft", "AltLeft", "Delete"]),
        ("PrtSc", ["PrintScreen"]), ("Esc", ["Escape"]), ("Lock", ["MetaLeft", "KeyL"]),
        ("Desk ←", ["ControlLeft", "AltLeft", "ArrowLeft"]), ("Desk →", ["ControlLeft", "AltLeft", "ArrowRight"]),
    ]

    enum Resolution { case window, native, mode(DisplayMode) }

    /// Rows of the resolution list: this window exactly (a host that can make its desktop any size),
    /// Native, the mode that best fills the window (one that can't), then every mode.
    var resolutionRows: [(title: String, detail: String, choice: Resolution, current: Bool)] {
        guard let m = modes, !m.modes.isEmpty else { return [] }
        let fitted = m.fitted != nil
        var rows: [(String, String, Resolution, Bool)] = []
        if !m.fitScales.isEmpty {
            let f = Fit.request(pixels: windowPixels, scale: 0)
            rows.append(("This window", m.fitted?.description ?? f?.description ?? "", .window, fitted))
        }
        rows.append(("Native", m.native?.description ?? "", .native, !fitted && m.current == m.native))
        if m.fitScales.isEmpty, let best = DisplayMode.bestFor(window: windowPixels, among: m.modes), best != m.native {
            rows.append(("Fit this window", best.description, .mode(best), false))
        }
        for mode in m.modes where mode != m.native {
            rows.append((mode.description, "", .mode(mode), !fitted && mode == m.current))
        }
        return rows
    }

    func choose(_ r: Resolution) {
        switch r {
        case .window: fitThisWindow()
        case .native: setResolution(nil)
        case .mode(let m): setResolution(m)
        }
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
    /// This window's computer: its choices are its own.
    @ObservedObject var computer: ComputerSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let st = model.stream {
                InEffectSection(e: InEffect(stream: st, targetKbps: model.targetKbps, chosenKbps: computer.prefs.quality,
                                            fullGPU: computer.prefs.fullGPU, decodesFullColour: DecoderCaps.fullColour),
                                notice: model.notice)
            }
            PanelSection(title: "Remote resolution") {
                let rows = model.resolutionRows
                if rows.isEmpty {
                    Text("Not available").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(rows.indices, id: \.self) { i in
                                let r = rows[i]
                                Button { model.choose(r.choice) } label: {
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
            if let offered = model.modes?.fitScales, offered.count > 1 {
                PanelSection(title: "Size") {
                    Picker("Size", selection: Binding(get: { model.fitScale }, set: { model.setFitScale($0) })) {
                        ForEach(offered, id: \.self) { Text("\($0) %").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(model.modes?.fitted == nil)
                    .help("How large the Linux desktop draws things in this window (200 % looks like a Retina screen)")
                }
            }
            if model.modes?.fitted == nil {                   // (a fitted desktop is one pixel per pixel anyway)
                PanelSection(title: "Scaling") {
                    Picker("Scaling", selection: $computer.prefs.scale) {
                        Text("Fit").tag(ScaleMode.fit)
                        Text("Actual size").tag(ScaleMode.actual)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            PanelSection(title: "Quality") {
                QualityPicker(selection: $computer.prefs.quality)
            }
            PanelSection(title: "Frame rate") {
                Picker("Frame rate", selection: $computer.prefs.fps) {
                    ForEach(Settings.frameRates, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            PanelSection(title: "Encoding") {
                Toggle("Use more of the Linux computer’s GPU", isOn: $computer.prefs.fullGPU)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Text("Sharper when scrolling fast.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct KeysPanel: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var computer: ComputerSettings

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
                Picker("⌘ Command sends", selection: $computer.prefs.command) {
                    Text("Ctrl").tag(CommandKey.ctrl)
                    Text("Super").tag(CommandKey.super)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            PanelSection(title: "System shortcuts") {
                Toggle("Send ⌘Tab, ⌘Space, Mission Control… too", isOn: $computer.prefs.captureSystemKeys)
                if computer.prefs.captureSystemKeys && !model.accessibilityTrusted {
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
                    Slider(value: $computer.prefs.scrollSpeed, in: 0.25...3, step: 0.25).accessibilityLabel("Scroll speed")
                    Toggle("Reverse", isOn: $computer.prefs.invertScroll)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// What's in effect, so a choice that didn't take shows (GPU memory full, say).
private struct InEffectSection: View {
    let e: InEffect
    let notice: String?

    var body: some View {
        PanelSection(title: "In effect") {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.picture)
                Text(e.colour)
                Text(e.encoding)
                if let b = e.bitrate { Text(b) }
            }
            .font(.system(size: 12))
            if !e.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(e.notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill") }
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
        }
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
                .help("\(q.kbps / 1000) Mbit/s; less only while the network needs it")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
    }
}

/// The first-connection tip: what the toolbar holds, and that it moves (the browser's words).
struct ToolbarTip: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your controls").font(.system(size: 13, weight: .semibold))
            Text("Full screen, display, keyboard, files and sound are all here.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("Drag the grip to move it anywhere.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it", action: done).controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 250)
    }
}
