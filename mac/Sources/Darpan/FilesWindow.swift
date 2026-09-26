import AppKit
import DarpanCore
import SwiftUI
import UniformTypeIdentifiers

/// One side of the Files window: a folder on this Mac or on the remote computer.
final class FilePane: ObservableObject {
    enum Side { case local, remote }

    let side: Side
    @Published private(set) var path: String
    @Published private(set) var entries: [FileEntry] = []
    @Published var selection = Set<FileEntry.ID>()
    @Published var sortOrder = [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
    @Published var showHidden = false { didSet { refresh() } }
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var all: [FileEntry] = []
    private var generation = 0
    var home: String
    var remote: FSClient?

    init(side: Side, home: String) {
        self.side = side
        self.home = home
        path = home
    }

    var title: String { side == .local ? "This Mac" : "Remote computer" }
    var selected: [FileEntry] { entries.filter { selection.contains($0.id) } }
    var localURL: URL { URL(fileURLWithPath: path, isDirectory: true) }

    func go(_ p: String) {
        path = p
        selection = []
        refresh()
    }

    func up() { go(FileNames.parent(path)) }
    func goHome() { go(home) }

    func open(_ e: FileEntry) {
        if e.isDirectory { go(FileNames.join(path, e.name)) }
        else if side == .local { NSWorkspace.shared.open(localURL.appendingPathComponent(e.name)) }
    }

    func refresh() {
        generation += 1
        let g = generation
        loading = true
        let finish: (Result<[FileEntry], FSError>) -> Void = { [weak self] r in
            DispatchQueue.main.async {
                guard let self, g == self.generation else { return }        // a newer listing wins
                self.loading = false
                switch r {
                case .success(let e): self.all = e; self.error = nil
                case .failure(let e): self.all = []; self.error = "Can’t open this folder: \(e.message)."
                }
                self.resort()
            }
        }
        switch side {
        case .local:
            let url = localURL
            DispatchQueue.global(qos: .userInitiated).async { finish(Self.listLocal(url)) }
        case .remote:
            guard let remote else { return finish(.failure(.host("token", status: 401))) }
            remote.list(path, deep: false) { r in finish(r.map(\.entries)) }
        }
    }

    func resort() {
        let visible = showHidden ? all : all.filter { !$0.name.hasPrefix(".") }
        let dirs = visible.filter(\.isDirectory).sorted(using: sortOrder)
        let files = visible.filter { !$0.isDirectory }.sorted(using: sortOrder)
        entries = dirs + files
        selection = selection.intersection(entries.map(\.id))
    }

    private static func listLocal(_ url: URL) -> Result<[FileEntry], FSError> {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else {
            return .failure(.local("permission denied"))
        }
        return .success(urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            let kind: FileEntry.Kind = v.isDirectory == true ? .directory : v.isRegularFile == true ? .file : .other
            return FileEntry(name: u.lastPathComponent, kind: kind, size: Int64(v.fileSize ?? 0),
                             modified: v.contentModificationDate ?? .distantPast, link: v.isSymbolicLink == true)
        })
    }

    func newFolder(_ name: String) {
        let target = FileNames.join(path, name)
        switch side {
        case .local:
            do {
                try FileManager.default.createDirectory(at: localURL.appendingPathComponent(name), withIntermediateDirectories: false)
                refresh()
            } catch { self.error = "Couldn’t create “\(name)”." }
        case .remote:
            remote?.mkdir(target) { [weak self] r in
                DispatchQueue.main.async {
                    if case .failure(let e) = r { self?.error = "Couldn’t create “\(name)”: \(e.message)." }
                    self?.refresh()
                }
            }
        }
    }
}

/// The Files window's state: both panes and the transfers between them.
final class FilesModel: ObservableObject {
    let local: FilePane
    let remote: FilePane
    @Published private(set) var transfers: [Transfers.Item] = []
    private(set) var engine: Transfers?
    weak var window: NSWindow?

    init() {
        local = FilePane(side: .local, home: FileManager.default.homeDirectoryForCurrentUser.path)
        remote = FilePane(side: .remote, home: "/")
        local.refresh()
    }

    /// A (new) file token: after connecting, or after a reconnect.
    func attach(_ access: FilesAccess, origin: URL, proxy: SOCKSProxy?) {
        let fs = FSClient(origin: origin, access: access, proxy: proxy)
        let firstTime = remote.remote == nil
        remote.remote = fs
        remote.home = access.home
        // The old token ended with its session; anything still running with it can't finish.
        engine?.cancelAll()
        let t = Transfers(remote: fs)
        var wasIdle = true
        t.onChange = { [weak self, weak t] in
            guard let self, let t else { return }
            self.transfers = t.items
            if t.isIdle && !wasIdle { self.remote.refresh(); self.local.refresh() }
            wasIdle = t.isIdle
        }
        t.ask = { [weak self] name, isFolder, reply in self?.askConflict(name, isFolder: isFolder, reply) }
        engine = t
        transfers = []
        if firstTime { remote.go(access.home) } else { remote.refresh() }
    }

    var canSend: Bool { engine != nil && !local.selected.isEmpty }
    var canReceive: Bool { engine != nil && remote.selected.contains { $0.kind != .other } }

    func send() {
        let urls = local.selected.map { local.localURL.appendingPathComponent($0.name) }
        engine?.send(urls, to: remote.path)
    }

    func send(_ urls: [URL]) { engine?.send(urls, to: remote.path) }

    func receive() {
        engine?.receive(remote.selected, from: remote.path, to: local.localURL)
    }

    func cancel(_ id: Int) { engine?.cancel(id) }
    func clearFinished() { engine?.clearFinished() }

    func stop() { engine?.cancelAll() }

    private func askConflict(_ name: String, isFolder: Bool, _ reply: @escaping (Conflict, Bool) -> Void) {
        let a = NSAlert()
        a.messageText = "“\(name)” already exists here."
        a.informativeText = isFolder ? "Replace merges into the existing folder." : ""
        a.addButton(withTitle: "Keep Both")
        a.addButton(withTitle: isFolder ? "Merge" : "Replace")
        a.addButton(withTitle: "Skip")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "For all"
        let answer: (NSApplication.ModalResponse) -> Void = { r in
            let forAll = a.suppressionButton?.state == .on
            switch r {
            case .alertFirstButtonReturn: reply(.keepBoth, forAll)
            case .alertSecondButtonReturn: reply(.replace, forAll)
            default: reply(.skip, forAll)
            }
        }
        if let window { a.beginSheetModal(for: window, completionHandler: answer) } else { answer(a.runModal()) }
    }
}

// MARK: - views

struct FilesView: View {
    @ObservedObject var model: FilesModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                PaneView(pane: model.local, model: model).frame(minWidth: 300)
                PaneView(pane: model.remote, model: model).frame(minWidth: 300)
            }
            Divider()
            TransferList(model: model)
        }
        .frame(minWidth: 680, minHeight: 440)
    }
}

private struct PaneView: View {
    @ObservedObject var pane: FilePane
    @ObservedObject var model: FilesModel
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(pane.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { pane.up() } label: { Image(systemName: "arrow.up") }.help("Enclosing folder").disabled(pane.path == "/")
                Button { pane.goHome() } label: { Image(systemName: "house") }.help("Home")
                Button { pane.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button { askNewFolder() } label: { Image(systemName: "folder.badge.plus") }.help("New folder")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.top, 8)
            Text(pane.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
            table
            HStack {
                Toggle("Hidden files", isOn: $pane.showHidden).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                if pane.side == .local {
                    Button("Send") { model.send() }.disabled(!model.canSend).help("Send the selection to the folder on the right")
                } else {
                    Button("Receive") { model.receive() }.disabled(!model.canReceive).help("Receive the selection into the folder on the left")
                }
            }
            .padding(8)
        }
    }

    private var table: some View {
        Table(pane.entries, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { e in
                Label {
                    Text(e.name).lineLimit(1)
                } icon: {
                    Image(systemName: e.isDirectory ? "folder.fill" : e.kind == .file ? "doc" : "questionmark.square.dashed")
                        .foregroundStyle(e.isDirectory ? Color.accentColor : .secondary)
                }
            }
            .width(min: 120, ideal: 180)
            TableColumn("Size", value: \.size) { e in
                Text(e.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64, max: 100)
            TableColumn("Modified", value: \.modified) { e in
                Text(Self.date(e.modified)).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .onChange(of: pane.sortOrder) { pane.resort() }
        .contextMenu(forSelectionType: FileEntry.ID.self) { _ in
            if pane.side == .local { Button("Send") { model.send() }.disabled(!model.canSend) }
            else { Button("Receive") { model.receive() }.disabled(!model.canReceive) }
        } primaryAction: { ids in
            if ids.count == 1, let e = pane.entries.first(where: { ids.contains($0.id) }) { pane.open(e) }
        }
        .overlay {
            if let e = pane.error {
                Text(e).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            } else if pane.loading && pane.entries.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .onDrop(of: pane.side == .remote ? [.fileURL] : [], isTargeted: $dropTarget) { providers in
            loadURLs(providers) { model.send($0) }
            return true
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: dropTarget ? 2 : 0))
    }

    /// Today: the time; otherwise the date.
    static func date(_ d: Date) -> String {
        if d == .distantPast { return "" }
        return Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(date: .numeric, time: .omitted)
    }

    private func askNewFolder() {
        let a = NSAlert()
        a.messageText = "New folder"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "untitled folder"
        a.accessoryView = field
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        let done: (NSApplication.ModalResponse) -> Void = { r in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard r == .alertFirstButtonReturn, !name.isEmpty, !name.contains("/") else { return }
            pane.newFolder(name)
        }
        if let w = model.window { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }
}

private func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { u, _ in
            if let u, u.isFileURL { lock.lock(); urls.append(u); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { if !urls.isEmpty { done(urls) } }
}

private struct TransferList: View {
    @ObservedObject var model: FilesModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.transfers.contains(where: { !Self.active($0.state) }) {
                    Button("Clear") { model.clearFinished() }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if model.transfers.isEmpty {
                Text("Select files or folders and click Send or Receive, or drop files from the Finder on the right.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.transfers.reversed()) { row($0) }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                }
                .frame(height: 110)
            }
        }
    }

    static func active(_ s: Transfers.State) -> Bool { s == .waiting || s == .running }

    private func row(_ t: Transfers.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: t.direction == .send ? "arrow.right" : "arrow.left").foregroundStyle(.secondary)
            Image(systemName: t.isFolder ? "folder" : "doc").foregroundStyle(.secondary)
            Text(t.name).lineLimit(1).truncationMode(.middle).frame(width: 180, alignment: .leading)
            switch t.state {
            case .running where t.total > 0:
                ProgressView(value: Double(t.sent), total: Double(max(t.total, t.sent))).frame(maxWidth: .infinity)
            case .running:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            default:
                Text(Self.status(t)).foregroundStyle(Self.isFailure(t.state) ? Color(nsColor: .systemRed) : .secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            if Self.active(t.state) {
                Button { model.cancel(t.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Cancel")
            }
        }
        .font(.system(size: 11))
    }

    static func isFailure(_ s: Transfers.State) -> Bool { if case .failed = s { return true } else { return false } }

    static func status(_ t: Transfers.Item) -> String {
        switch t.state {
        case .waiting: return "Waiting"
        case .running: return ""
        case .done: return "Done" + (t.total > 0 ? " · " + ByteCountFormatter.string(fromByteCount: t.total, countStyle: .file) : "")
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        case .failed(let why): return "Failed: \(why)"
        }
    }
}

final class FilesWindowController: NSWindowController, NSWindowDelegate {
    let model = FilesModel()

    init(title: String) {
        let host = NSHostingController(rootView: FilesView(model: model))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = title
        w.setContentSize(NSSize(width: 820, height: 560))
        w.setFrameAutosaveName("DarpanFiles")
        super.init(window: w)
        w.delegate = self
        model.window = w
    }

    required init?(coder: NSCoder) { fatalError() }
}
