import DarpanCore
import Foundation

/// A stand-in host: PROTOCOL.md §7.1 semantics on a folder of this Mac.
private final class FolderRemote: RemoteFS {
    let root: URL
    var failNextPuts = 0                    // simulate dropped connections
    var cutDownloadAt: Int64?               // a download stops after this many bytes, once
    var puts: [(String, String)] = []       // (path, exists)
    var mkdirs: [String] = []
    var ranges: [String?] = []
    private let fm = FileManager.default

    init(root: URL) { self.root = root }

    private func local(_ p: String) -> URL { root.appendingPathComponent(String(p.dropFirst())) }

    private final class Token: Cancellable { func cancel() {} }

    func list(_ path: String, deep: Bool, _ done: @escaping (Result<FSClient.Listing, FSError>) -> Void) {
        let base = local(path)
        var out: [FileEntry] = []
        if deep, let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
            var all: [URL] = []
            for case let u as URL in en { all.append(u) }
            let b = base.standardizedFileURL.path
            for u in all {
                let rel = String(u.standardizedFileURL.path.dropFirst(b.count + 1))
                out.append(entry(u, name: rel))
            }
        } else {
            guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return done(.failure(.host("notfound", status: 404))) }
            out = names.map { entry(base.appendingPathComponent($0), name: $0) }
        }
        DispatchQueue.global().async { done(.success(.init(path: path, entries: out, more: false))) }
    }

    private func entry(_ u: URL, name: String) -> FileEntry {
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        return FileEntry(name: name, kind: v?.isDirectory == true ? .directory : .file, size: Int64(v?.fileSize ?? 0), modified: Date())
    }

    func mkdir(_ path: String, _ done: @escaping (Result<String, FSError>) -> Void) {
        mkdirs.append(path)
        let u = local(path)
        if fm.fileExists(atPath: u.path) { return done(.failure(.host("exists", status: 409))) }
        do { try fm.createDirectory(at: u, withIntermediateDirectories: false); done(.success(path)) } catch { done(.failure(.host("notfound", status: 404))) }
    }

    func upload(_ file: URL, to path: String, exists: String, progress: @escaping (Int64) -> Void,
                _ done: @escaping (Result<String, FSError>) -> Void) -> Cancellable {
        puts.append((path, exists))
        DispatchQueue.global().async { [self] in
            if failNextPuts > 0 { failNextPuts -= 1; return done(.failure(.network)) }
            var dest = local(path)
            if fm.fileExists(atPath: dest.path) {
                switch exists {
                case "replace": try? fm.removeItem(at: dest)
                case "rename":
                    let taken = Set((try? fm.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? [])
                    dest = dest.deletingLastPathComponent().appendingPathComponent(FileNames.unique(dest.lastPathComponent, taken: taken))
                default: return done(.failure(.host("exists", status: 409)))
                }
            }
            do {
                try fm.copyItem(at: file, to: dest)
                progress(Int64((try? Data(contentsOf: file))?.count ?? 0))
                done(.success("/" + String(dest.path.dropFirst(root.path.count + 1))))
            } catch { done(.failure(.host("notfound", status: 404))) }
        }
        return Token()
    }

    func download(_ path: String, to file: URL, resume: String?, progress: @escaping (Int64, Int64) -> Void,
                  _ done: @escaping (Result<URL, FSError>, String?) -> Void) -> Cancellable {
        ranges.append(resume)
        DispatchQueue.global().async { [self] in
            guard let data = try? Data(contentsOf: local(path)) else { return done(.failure(.host("notfound", status: 404)), nil) }
            let part = FSClient.partialFile(for: file)
            var have = Data()
            if resume == "etag-1", let p = try? Data(contentsOf: part) { have = p }
            if let cut = cutDownloadAt {
                cutDownloadAt = nil
                try? data.prefix(Int(cut)).write(to: part)
                return done(.failure(.network), "etag-1")
            }
            let body = have + data.dropFirst(have.count)
            try? body.write(to: part)
            _ = try? fm.replaceItemAt(file, withItemAt: part)
            progress(Int64(body.count), Int64(body.count))
            done(.success(file), "etag-1")
        }
        return Token()
    }
}

private func waitIdle(_ t: Transfers, _ what: String, seconds: Double = 10) {
    let end = Date().addingTimeInterval(seconds)
    while !t.isIdle && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(t.isIdle, "\(what): finished in time")
}

func filesTests() {
    section("file names") {
        eq(FileNames.unique("a.txt", taken: ["a.txt"]), "a (1).txt", "first free name")
        eq(FileNames.unique("a.txt", taken: ["a.txt", "a (1).txt"]), "a (2).txt", "next free name")
        eq(FileNames.unique("notes", taken: ["notes"]), "notes (1)", "no extension")
        eq(FileNames.unique(".bashrc", taken: [".bashrc"]), ".bashrc (1)", "dotfile")
        eq(FileNames.unique("b.txt", taken: ["a.txt"]), "b.txt", "free already")
        eq(FileNames.join("/srv/u", "x"), "/srv/u/x", "join")
        eq(FileNames.join("/", "x"), "/x", "join at the root")
        eq(FileNames.parent("/srv/u"), "/srv", "parent")
        eq(FileNames.parent("/srv"), "/", "parent of a top folder")
    }

    section("listing JSON") {
        let json = Data(#"{"path":"/h","entries":[{"name":"a.txt","type":"f","size":12,"mtime":1727350000,"link":false},{"name":"d","type":"d","size":0,"mtime":1,"link":true},{"name":"s","type":"o"}],"more":true}"#.utf8)
        let l = FSClient.parseListing(json)
        eq(l?.entries.count, 3, "entries")
        eq(l?.entries.first?.size, 12, "size")
        eq(l?.entries[1].isDirectory, true, "folder")
        eq(l?.entries[1].link, true, "link")
        eq(l?.entries[2].kind, .other, "other")
        eq(l?.more, true, "more")
    }

    section("request URLs") {
        let c = FSClient(origin: URL(string: "https://pc.example.ts.net")!, access: FilesAccess(token: "t", home: "/h", inbox: "/h/Desktop"), proxy: nil)
        eq(c.url("list", ["path": "/srv/u/a b+c&d.txt"]).absoluteString,
           "https://pc.example.ts.net/fs/list?path=/srv/u/a%20b%2Bc%26d.txt", "path is percent-encoded, + and & too")
        eq(c.url("file", ["path": "/x", "exists": "rename"]).query, "exists=rename&path=/x", "several parameters")
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("darpan-files-\(UUID().uuidString)")
    let fm = FileManager.default
    defer { try? fm.removeItem(at: tmp) }
    let mac = tmp.appendingPathComponent("mac"), host = tmp.appendingPathComponent("host")

    section("send files and folders, conflicts") {
        try fm.createDirectory(at: mac.appendingPathComponent("proj/src/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: host.appendingPathComponent("srv"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: mac.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: mac.appendingPathComponent("proj/readme"))
        try Data("three".utf8).write(to: mac.appendingPathComponent("proj/src/deep/x.c"))
        let remote = FolderRemote(root: host)
        let t = Transfers(remote: remote)
        t.retryDelay = 0
        t.send([mac.appendingPathComponent("a.txt"), mac.appendingPathComponent("proj")], to: "/srv")
        waitIdle(t, "first send")
        eq(t.items.map(\.state), [.done, .done], "both done")
        eq(try? String(contentsOf: host.appendingPathComponent("srv/proj/src/deep/x.c")), "three", "nested file arrived")
        eq(remote.mkdirs, ["/srv/proj", "/srv/proj/src", "/srv/proj/src/deep"], "folders made shallowest first")
        eq(t.items[1].total, 8, "folder size is its files' total")

        // Send again: both names are taken now.
        var asked: [String] = []
        t.ask = { name, _, reply in asked.append(name); reply(.keepBoth, true) }
        t.send([mac.appendingPathComponent("a.txt"), mac.appendingPathComponent("proj")], to: "/srv")
        waitIdle(t, "keep both")
        eq(asked, ["a.txt"], "asked once, then \"for all\"")
        check(fm.fileExists(atPath: host.appendingPathComponent("srv/a (1).txt").path), "kept both: a (1).txt")
        check(fm.fileExists(atPath: host.appendingPathComponent("srv/proj (1)/src/deep/x.c").path), "kept both: proj (1)")

        try Data("ONE".utf8).write(to: mac.appendingPathComponent("a.txt"))
        t.ask = { _, _, reply in reply(.replace, false) }
        t.send([mac.appendingPathComponent("a.txt"), mac.appendingPathComponent("proj")], to: "/srv")
        waitIdle(t, "replace")
        eq(try? String(contentsOf: host.appendingPathComponent("srv/a.txt")), "ONE", "replaced")
        check(remote.puts.suffix(3).allSatisfy { $0.1 == "replace" }, "replace/merge uploads use exists=replace")
        eq(t.items.suffix(2).map(\.state), [.done, .done], "replace done; the folder merged")

        t.ask = { _, _, reply in reply(.skip, true) }
        t.send([mac.appendingPathComponent("a.txt")], to: "/srv")
        waitIdle(t, "skip")
        eq(t.items.last?.state, .skipped, "skipped")

        remote.failNextPuts = 2
        try Data("new".utf8).write(to: mac.appendingPathComponent("b.txt"))
        t.send([mac.appendingPathComponent("b.txt")], to: "/srv")
        waitIdle(t, "retry")
        eq(t.items.last?.state, .done, "two dropped connections are retried")
        remote.failNextPuts = 3
        try Data("new".utf8).write(to: mac.appendingPathComponent("c.txt"))
        t.send([mac.appendingPathComponent("c.txt")], to: "/srv")
        waitIdle(t, "gives up")
        eq(t.items.last?.state, .failed(FSError.network.message), "the third failure is reported")
    }

    section("receive files and folders, resume") {
        let down = tmp.appendingPathComponent("down")
        try fm.createDirectory(at: down, withIntermediateDirectories: true)
        let remote = FolderRemote(root: host)
        let t = Transfers(remote: remote)
        t.retryDelay = 0
        let big = Data((0..<100_000).map { UInt8($0 % 251) })
        try big.write(to: host.appendingPathComponent("srv/big.bin"))
        remote.cutDownloadAt = 40_000
        t.receive([FileEntry(name: "big.bin", kind: .file, size: 100_000, modified: Date()),
                   FileEntry(name: "proj", kind: .directory, size: 0, modified: Date()),
                   FileEntry(name: "sock", kind: .other, size: 0, modified: Date())], from: "/srv", to: down)
        waitIdle(t, "receive")
        eq(t.items.map(\.state), [.done, .done], "file and folder done; the socket isn't offered")
        eq(try? Data(contentsOf: down.appendingPathComponent("big.bin")), big, "resumed download is intact")
        eq(remote.ranges.prefix(2).map { $0 ?? "-" }, ["-", "etag-1"], "the retry resumes with the ETag")
        check(!fm.fileExists(atPath: FSClient.partialFile(for: down.appendingPathComponent("big.bin")).path), "no partial file left")
        eq(try? String(contentsOf: down.appendingPathComponent("proj/src/deep/x.c")), "three", "folder tree received")

        t.ask = { _, _, reply in reply(.keepBoth, false) }
        t.receive([FileEntry(name: "big.bin", kind: .file, size: 100_000, modified: Date())], from: "/srv", to: down)
        waitIdle(t, "receive again")
        check(fm.fileExists(atPath: down.appendingPathComponent("big (1).bin").path), "kept both locally")
    }
}
