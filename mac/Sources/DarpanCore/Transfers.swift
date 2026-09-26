import Foundation

/// Something that can be stopped: a request in flight.
public protocol Cancellable: AnyObject {
    func cancel()
}

extension URLSessionTask: Cancellable {}

/// The remote side of transfers: FSClient, or a stand-in in tests.
public protocol RemoteFS: AnyObject {
    func list(_ path: String, deep: Bool, _ done: @escaping (Result<FSClient.Listing, FSError>) -> Void)
    func mkdir(_ path: String, _ done: @escaping (Result<String, FSError>) -> Void)
    @discardableResult
    func upload(_ file: URL, to path: String, exists: String, progress: @escaping (Int64) -> Void,
                _ done: @escaping (Result<String, FSError>) -> Void) -> Cancellable
    @discardableResult
    func download(_ path: String, to file: URL, resume: String?, progress: @escaping (Int64, Int64) -> Void,
                  _ done: @escaping (Result<URL, FSError>, _ etag: String?) -> Void) -> Cancellable
}

extension FSClient: RemoteFS {}

/// Sending and receiving files and folders, one item at a time (a folder is one item). All
/// methods and callbacks run on the main queue.
///
/// A name that's already taken where an item goes is resolved by `ask` (Skip / Keep both /
/// Replace, optionally for the rest of the batch). Replacing a folder merges into it. Dropped
/// connections are retried twice, and a download continues where it stopped when the remote
/// file hasn't changed (`If-Range`).
public final class Transfers {
    public enum Direction { case send, receive }

    public enum State: Equatable {
        case waiting, running, done, skipped, cancelled
        case failed(String)
    }

    public struct Item: Identifiable, Equatable {
        public let id: Int
        public let name: String
        public let direction: Direction
        public var state: State = .waiting
        public var total: Int64 = 0
        public var sent: Int64 = 0
        public var isFolder: Bool
        /// Where it ended up (a remote path, or a local file).
        public var destination: String?
    }

    public private(set) var items: [Item] = []
    public var onChange: (() -> Void)?
    /// `name` already exists at the destination: answer with what to do, and whether for all of
    /// this batch.
    public var ask: (_ name: String, _ isFolder: Bool, _ reply: @escaping (Conflict, _ forAll: Bool) -> Void) -> Void = { _, _, r in r(.keepBoth, false) }

    private let remote: RemoteFS
    private var jobs: [Int: Job] = [:]
    private var queue: [Int] = []
    private var current: Cancellable?
    private var running: Int?
    private var nextID = 1
    private let fm = FileManager.default
    /// Pause before retrying a dropped request (seconds); 0 in tests.
    public var retryDelay = 2.0

    private enum Job {
        case send(URL, folder: String, batch: Batch)
        case receive(FileEntry, folder: String, to: URL, batch: Batch)
    }

    /// One Send or Receive: the names taken at the destination, and a "for all" answer.
    private final class Batch {
        var taken: Set<String>?
        var answer: Conflict?
    }

    public init(remote: RemoteFS) {
        self.remote = remote
    }

    public var isIdle: Bool { running == nil && queue.isEmpty }

    // MARK: - public

    public func send(_ urls: [URL], to folder: String) {
        let b = Batch()
        for u in urls {
            let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            add(u.lastPathComponent, .send, folder: dir, .send(u, folder: folder, batch: b))
        }
        pump()
    }

    public func receive(_ entries: [FileEntry], from folder: String, to local: URL) {
        let b = Batch()
        for e in entries where e.kind != .other && FileNames.isSafeRelative(e.name, nested: false) {
            add(e.name, .receive, folder: e.isDirectory, .receive(e, folder: folder, to: local, batch: b))
        }
        pump()
    }

    public func cancel(_ id: Int) {
        guard let i = index(id), !finished(items[i].state) else { return }
        if running == id {
            current?.cancel()                           // its completion ends the item
            running = nil
            current = nil
        }
        queue.removeAll { $0 == id }
        jobs[id] = nil
        items[i].state = .cancelled
        changed()
        pump()
    }

    public func cancelAll() {
        for i in items where !finished(i.state) { cancel(i.id) }
    }

    /// Finished items leave the list.
    public func clearFinished() {
        items.removeAll { finished($0.state) }
        changed()
    }

    // MARK: - queue

    private func add(_ name: String, _ d: Direction, folder: Bool, _ job: Job) {
        let id = nextID
        nextID += 1
        items.append(Item(id: id, name: name, direction: d, isFolder: folder))
        jobs[id] = job
        queue.append(id)
        changed()
    }

    private func index(_ id: Int) -> Int? { items.firstIndex { $0.id == id } }

    private func finished(_ s: State) -> Bool {
        switch s {
        case .waiting, .running: return false
        default: return true
        }
    }

    private func changed() { onChange?() }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let job = jobs[id], let i = index(id) else { return pump() }
        running = id
        items[i].state = .running
        changed()
        switch job {
        case .send(let url, let folder, let batch): startSend(id, url, folder, batch)
        case .receive(let e, let folder, let local, let batch): startReceive(id, e, folder, local, batch)
        }
    }

    /// Ends the running item (ignored if it was cancelled meanwhile).
    private func end(_ id: Int, _ state: State, destination: String? = nil) {
        guard running == id, let i = index(id) else { return }
        items[i].state = state
        if let destination { items[i].destination = destination }
        if state == .done { items[i].sent = items[i].total }
        running = nil
        current = nil
        jobs[id] = nil
        changed()
        pump()
    }

    private func alive(_ id: Int) -> Bool { running == id }

    private func progress(_ id: Int, sent: Int64, total: Int64? = nil) {
        guard alive(id), let i = index(id) else { return }
        items[i].sent = sent
        if let total { items[i].total = total }
        changed()
    }

    /// Resolves a taken name: nil to skip, else the name to use and whether it replaces/merges.
    private func resolve(_ name: String, folder: Bool, batch: Batch, _ done: @escaping ((name: String, replace: Bool)?) -> Void) {
        let taken = batch.taken ?? []
        guard taken.contains(name) else { batch.taken?.insert(name); return done((name, false)) }
        let apply = { (c: Conflict) in
            switch c {
            case .skip: done(nil)
            case .replace: done((name, true))
            case .keepBoth:
                let n = FileNames.unique(name, taken: taken)
                batch.taken?.insert(n)
                done((n, false))
            }
        }
        if let a = batch.answer { return apply(a) }
        ask(name, folder) { c, forAll in
            if forAll { batch.answer = c }
            apply(c)
        }
    }

    // MARK: - sending

    private func startSend(_ id: Int, _ url: URL, _ folder: String, _ batch: Batch) {
        withRemoteNames(id, folder, batch) {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            self.resolve(url.lastPathComponent, folder: isDir, batch: batch) { r in
                guard self.alive(id) else { return }
                guard let r else { return self.end(id, .skipped) }
                let dest = FileNames.join(folder, r.name)
                if isDir {
                    self.sendFolder(id, url, dest, merge: r.replace)
                } else {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
                    self.progress(id, sent: 0, total: size)
                    self.put(id, url, dest, exists: r.replace ? "replace" : "fail", base: 0) { result in
                        switch result {
                        case .success(let path): self.end(id, .done, destination: path)
                        case .failure(let e): self.end(id, e == .cancelled ? .cancelled : .failed(e.message))
                        }
                    }
                }
            }
        }
    }

    /// Fetches the destination's names once per batch.
    private func withRemoteNames(_ id: Int, _ folder: String, _ batch: Batch, _ then: @escaping () -> Void) {
        if batch.taken != nil { return then() }
        remote.list(folder, deep: false) { r in
            DispatchQueue.main.async {
                guard self.alive(id) else { return }
                switch r {
                case .success(let l): batch.taken = Set(l.entries.map(\.name)); then()
                case .failure(let e): self.end(id, .failed(e.message))
                }
            }
        }
    }

    /// Everything below a local folder, not following links: folders (shallowest first) and
    /// files, or the first thing that couldn't be read.
    private static func scan(_ url: URL) -> Result<(dirs: [String], files: [(URL, String, Int64)]), FSError> {
        var dirs: [String] = [], files: [(URL, String, Int64)] = []
        var unreadable: String?
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let base = url.standardizedFileURL.path
        let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) { u, _ in
            unreadable = unreadable ?? u.lastPathComponent
            return false
        }
        while let u = en?.nextObject() as? URL {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { unreadable = u.lastPathComponent; break }
            if v.isSymbolicLink == true { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            if v.isDirectory == true { dirs.append(rel) } else if v.isRegularFile == true { files.append((u, rel, Int64(v.fileSize ?? 0))) }
        }
        if let unreadable { return .failure(.local("couldn’t read “\(unreadable)”")) }
        dirs.sort { ($0.filter { $0 == "/" }.count, $0) < ($1.filter { $0 == "/" }.count, $1) }
        return .success((dirs, files))
    }

    private func sendFolder(_ id: Int, _ url: URL, _ dest: String, merge: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.scan(url)
            DispatchQueue.main.async {
                guard self.alive(id) else { return }
                switch r {
                case .success(let s): self.sendTree(id, s.dirs, s.files, dest, merge: merge)
                case .failure(let e): self.end(id, .failed(e.message))
                }
            }
        }
    }

    private func sendTree(_ id: Int, _ dirs: [String], _ files: [(URL, String, Int64)], _ dest: String, merge: Bool) {
        let total = files.reduce(0) { $0 + $1.2 }
        progress(id, sent: 0, total: total)
        let paths = [dest] + dirs.map { FileNames.join(dest, $0) }
        makeDirs(id, paths, ok: merge) { [self] in
            var done: Int64 = 0
            func next(_ k: Int) {
                guard alive(id) else { return }
                guard k < files.count else { return end(id, .done, destination: dest) }
                let (u, rel, size) = files[k]
                put(id, u, FileNames.join(dest, rel), exists: merge ? "replace" : "fail", base: done) { r in
                    switch r {
                    case .success:
                        done += size
                        next(k + 1)
                    case .failure(let e):
                        self.end(id, e == .cancelled ? .cancelled : .failed("\(rel): \(e.message)"))
                    }
                }
            }
            next(0)
        }
    }

    /// Creates remote folders in order. `ok`: one that already exists is fine (merging); the
    /// folder's own subfolders always are.
    private func makeDirs(_ id: Int, _ paths: [String], ok: Bool, _ then: @escaping () -> Void) {
        guard let p = paths.first else { return then() }
        remote.mkdir(p) { r in
            DispatchQueue.main.async {
                guard self.alive(id) else { return }
                if case .failure(let e) = r, !(e == .host("exists", status: 409) && ok) {
                    return self.end(id, .failed(e.message))
                }
                self.makeDirs(id, Array(paths.dropFirst()), ok: true, then)
            }
        }
    }

    /// One PUT, retried when the connection drops or the host is busy.
    private func put(_ id: Int, _ file: URL, _ path: String, exists: String, base: Int64, tries: Int = 0,
                     _ done: @escaping (Result<String, FSError>) -> Void) {
        current = remote.upload(file, to: path, exists: exists, progress: { n in
            DispatchQueue.main.async { self.progress(id, sent: base + n) }
        }) { r in
            DispatchQueue.main.async {
                guard self.alive(id) else { return }
                if case .failure(let e) = r, self.retryable(e), tries < 2 {
                    return self.later { if self.alive(id) { self.put(id, file, path, exists: exists, base: base, tries: tries + 1, done) } }
                }
                done(r)
            }
        }
    }

    private func retryable(_ e: FSError) -> Bool {
        e == .network || e == .host("busy", status: 429)
    }

    private func later(_ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: f)
    }

    // MARK: - receiving

    private func startReceive(_ id: Int, _ e: FileEntry, _ folder: String, _ local: URL, _ batch: Batch) {
        if batch.taken == nil { batch.taken = Set((try? fm.contentsOfDirectory(atPath: local.path)) ?? []) }
        resolve(e.name, folder: e.isDirectory, batch: batch) { r in
            guard self.alive(id) else { return }
            guard let r else { return self.end(id, .skipped) }
            let src = FileNames.join(folder, e.name)
            let dest = local.appendingPathComponent(r.name)
            if e.isDirectory {
                self.receiveFolder(id, src, dest)
            } else {
                self.progress(id, sent: 0, total: e.size)
                self.get(id, src, dest, base: 0) { res in
                    switch res {
                    case .success: self.end(id, .done, destination: dest.path)
                    case .failure(let err): self.end(id, err == .cancelled ? .cancelled : .failed(err.message))
                    }
                }
            }
        }
    }

    private func receiveFolder(_ id: Int, _ src: String, _ dest: URL) {
        remote.list(src, deep: true) { r in
            DispatchQueue.main.async {
                guard self.alive(id) else { return }
                let l: FSClient.Listing
                switch r {
                case .success(let x): l = x
                case .failure(let e): return self.end(id, .failed(e.message))
                }
                guard !l.more else { return self.end(id, .failed(FSError.tooMany.message)) }
                guard l.entries.allSatisfy({ FileNames.isSafeRelative($0.name, nested: true) }) else {
                    return self.end(id, .failed("the remote computer sent an invalid name"))
                }
                do {
                    try self.fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    for d in l.entries where d.isDirectory {
                        try self.fm.createDirectory(at: dest.appendingPathComponent(d.name), withIntermediateDirectories: true)
                    }
                } catch {
                    return self.end(id, .failed("couldn’t create the folder here"))
                }
                let files = l.entries.filter { $0.kind == .file }
                self.progress(id, sent: 0, total: files.reduce(0) { $0 + $1.size })
                var done: Int64 = 0
                func next(_ k: Int) {
                    guard self.alive(id) else { return }
                    guard k < files.count else { return self.end(id, .done, destination: dest.path) }
                    let f = files[k]
                    self.get(id, FileNames.join(src, f.name), dest.appendingPathComponent(f.name), base: done) { res in
                        switch res {
                        case .success:
                            done += f.size
                            next(k + 1)
                        case .failure(let e):
                            self.end(id, e == .cancelled ? .cancelled : .failed("\(f.name): \(e.message)"))
                        }
                    }
                }
                next(0)
            }
        }
    }

    /// One GET, continued after a dropped connection (If-Range with the ETag of the first try).
    private func get(_ id: Int, _ path: String, _ dest: URL, base: Int64, tries: Int = 0, etag: String? = nil,
                     _ done: @escaping (Result<URL, FSError>) -> Void) {
        current = remote.download(path, to: dest, resume: etag, progress: { n, _ in
            DispatchQueue.main.async { self.progress(id, sent: base + n) }
        }) { r, tag in
            DispatchQueue.main.async {
                guard self.alive(id) else {
                    try? self.fm.removeItem(at: FSClient.partialFile(for: dest))
                    return
                }
                if case .failure(let e) = r, self.retryable(e), tries < 2 {
                    return self.later { if self.alive(id) { self.get(id, path, dest, base: base, tries: tries + 1, etag: tag ?? etag, done) } }
                }
                if case .failure = r { try? self.fm.removeItem(at: FSClient.partialFile(for: dest)) }
                done(r)
            }
        }
    }
}
