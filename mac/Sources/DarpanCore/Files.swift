import Foundation
import Network

/// A folder entry, on either computer.
public struct FileEntry: Equatable, Hashable, Identifiable {
    public enum Kind: String { case directory = "d", file = "f", other = "o" }
    public var name: String
    public var kind: Kind
    public var size: Int64
    public var modified: Date
    public var link: Bool

    public var id: String { name }
    public var isDirectory: Bool { kind == .directory }

    public init(name: String, kind: Kind, size: Int64, modified: Date, link: Bool = false) {
        self.name = name; self.kind = kind; self.size = size; self.modified = modified; self.link = link
    }
}

/// What the host gives a session for file access (PROTOCOL.md §7.1, `{"t":"fs"}`).
public struct FilesAccess: Equatable {
    public let token: String
    public let home: String
    public let inbox: String

    public init(token: String, home: String, inbox: String) {
        self.token = token; self.home = home; self.inbox = inbox
    }
}

public enum FSError: Error, Equatable {
    /// The host's `{"e":…}` code: exists, notfound, denied, notdir, isdir, notfile, nospace, busy, token…
    case host(String, status: Int)
    case network
    case cancelled
    /// A folder with more entries than the host lists at once.
    case tooMany
    /// This Mac's side: a file couldn't be read or written.
    case local(String)

    public var message: String {
        switch self {
        case .host("exists", _): return "it already exists"
        case .host("notfound", _): return "it no longer exists"
        case .host("denied", _): return "permission denied"
        case .host("nospace", _): return "the remote disk is full"
        case .host("notfile", _): return "it isn’t a regular file"
        case .host("isdir", _): return "it’s a folder"
        case .host("notdir", _): return "that isn’t a folder"
        case .host("busy", _): return "the remote computer is busy"
        case .host("token", _): return "the session ended"
        case .host(let e, let s): return "the remote computer answered \(s) \(e)"
        case .network: return "the connection was lost"
        case .cancelled: return "cancelled"
        case .tooMany: return "the folder has too many items"
        case .local(let s): return s
        }
    }
}

/// When a name is already taken where a file goes.
public enum Conflict: Equatable {
    case skip, keepBoth, replace
}

/// The host's file API over HTTPS (PROTOCOL.md §7.1): one URLSession through the tailnet proxy,
/// each request with the session's bearer token. Completions run on an arbitrary queue.
public final class FSClient {
    public let access: FilesAccess
    private let origin: URL
    private let session: URLSession
    private let delegate = Delegate()

    public init(origin: URL, access: FilesAccess, proxy: SOCKSProxy?, protocolClasses: [AnyClass]? = nil) {
        self.origin = origin
        self.access = access
        let cfg = URLSessionConfiguration.ephemeral
        if let proxy, let port = NWEndpoint.Port(rawValue: proxy.port) {
            var p = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(proxy.host), port: port))
            p.applyCredential(username: proxy.username, password: proxy.password)
            p.allowFailover = false
            cfg.proxyConfigurations = [p]
        }
        cfg.httpMaximumConnectionsPerHost = 3            // the host allows 4 requests at once per session
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func url(_ op: String, _ query: [String: String]) -> URL {
        var c = URLComponents(url: origin.appendingPathComponent("fs/\(op)"), resolvingAgainstBaseURL: false)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `+` means a space in some query parsers; a path may contain it.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    private func request(_ op: String, _ query: [String: String], method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url(op, query))
        r.httpMethod = method
        r.setValue("Bearer \(access.token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private static func failure(_ data: Data?, _ response: URLResponse?, _ error: Error?) -> FSError? {
        if let e = error as? URLError { return e.code == .cancelled ? .cancelled : .network }
        if error != nil { return .network }
        guard let h = response as? HTTPURLResponse else { return .network }
        guard (200..<300).contains(h.statusCode) else {
            let code = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["e"] as? String
            return .host(code ?? "failed", status: h.statusCode)
        }
        return nil
    }

    // MARK: - listing, folders

    public struct Listing: Equatable {
        public var path: String
        public var entries: [FileEntry]
        public var more: Bool

        public init(path: String, entries: [FileEntry], more: Bool) {
            self.path = path; self.entries = entries; self.more = more
        }
    }

    public func list(_ path: String, deep: Bool, _ done: @escaping (Result<Listing, FSError>) -> Void) {
        var q = ["path": path]
        if deep { q["deep"] = "1" }
        session.dataTask(with: request("list", q)) { data, response, error in
            if let f = Self.failure(data, response, error) { return done(.failure(f)) }
            guard let data, let l = Self.parseListing(data) else { return done(.failure(.host("failed", status: 200))) }
            done(.success(l))
        }.resume()
    }

    public static func parseListing(_ data: Data) -> Listing? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = o["path"] as? String, let raw = o["entries"] as? [[String: Any]] else { return nil }
        let entries = raw.compactMap { e -> FileEntry? in
            guard let name = e["name"] as? String, !name.isEmpty else { return nil }
            let kind = FileEntry.Kind(rawValue: e["type"] as? String ?? "") ?? .other
            let size = (e["size"] as? NSNumber)?.int64Value ?? 0
            let mtime = (e["mtime"] as? NSNumber)?.doubleValue ?? 0
            return FileEntry(name: name, kind: kind, size: size, modified: Date(timeIntervalSince1970: mtime),
                             link: e["link"] as? Bool ?? false)
        }
        return Listing(path: path, entries: entries, more: o["more"] as? Bool ?? false)
    }

    public func mkdir(_ path: String, _ done: @escaping (Result<String, FSError>) -> Void) {
        session.dataTask(with: request("mkdir", ["path": path], method: "POST")) { data, response, error in
            if let f = Self.failure(data, response, error) { return done(.failure(f)) }
            done(.success(Self.path(data) ?? path))
        }.resume()
    }

    private static func path(_ data: Data?) -> String? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["path"] as? String
    }

    // MARK: - files

    /// PUT a local file to `path`. `exists`: fail, replace or rename. Returns the task, to cancel it.
    @discardableResult
    public func upload(_ file: URL, to path: String, exists: String, progress: @escaping (Int64) -> Void,
                       _ done: @escaping (Result<String, FSError>) -> Void) -> Cancellable {
        var r = request("file", ["path": path, "exists": exists], method: "PUT")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: r, fromFile: file) { data, response, error in
            if let f = Self.failure(data, response, error) { return done(.failure(f)) }
            done(.success(Self.path(data) ?? path))
        }
        delegate.onSent(task, progress)
        task.resume()
        return task
    }

    /// GET `path` into `file`, through a hidden partial file next to it. With `resume` (the ETag of
    /// an earlier attempt whose partial file is still there) it continues where that stopped,
    /// unless the remote file has changed since.
    @discardableResult
    public func download(_ path: String, to file: URL, resume: String? = nil, progress: @escaping (Int64, Int64) -> Void,
                         _ done: @escaping (Result<URL, FSError>, _ etag: String?) -> Void) -> Cancellable {
        let part = Self.partialFile(for: file)
        var r = request("file", ["path": path])
        var offset: Int64 = 0
        if let resume, let size = (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int64, size > 0 {
            offset = size
            r.setValue("bytes=\(size)-", forHTTPHeaderField: "Range")
            r.setValue(resume, forHTTPHeaderField: "If-Range")
        }
        let task = session.dataTask(with: r)
        delegate.onReceive(task, Receiver(part: part, file: file, offset: offset, progress: progress, done: done))
        task.resume()
        return task
    }

    public static func partialFile(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).darpan-part")
    }

    // MARK: - URLSession callbacks

    final class Receiver {
        let part: URL, file: URL
        var offset: Int64
        let progress: (Int64, Int64) -> Void
        let done: (Result<URL, FSError>, String?) -> Void
        var handle: FileHandle?
        var status = 0
        var etag: String?
        var total: Int64 = 0
        var received: Int64 = 0
        var error: Data?                                // an error answer's body
        var failed: FSError?

        init(part: URL, file: URL, offset: Int64, progress: @escaping (Int64, Int64) -> Void,
             done: @escaping (Result<URL, FSError>, String?) -> Void) {
            self.part = part; self.file = file; self.offset = offset; self.progress = progress; self.done = done
        }

        func start(_ response: HTTPURLResponse) -> Bool {
            status = response.statusCode
            etag = response.value(forHTTPHeaderField: "ETag")
            guard status == 200 || status == 206 else { error = Data(); return true }
            if status == 200 { offset = 0 }              // the whole file (new, or changed since)
            total = offset + max(0, response.expectedContentLength)
            let fm = FileManager.default
            if offset == 0 {
                try? fm.removeItem(at: part)
                guard fm.createFile(atPath: part.path, contents: nil) else { failed = .local("can’t write here"); return false }
            }
            guard let h = try? FileHandle(forWritingTo: part) else { failed = .local("can’t write here"); return false }
            _ = try? h.seekToEnd()
            handle = h
            return true
        }

        func write(_ data: Data) -> Bool {
            if error != nil { error!.append(data.prefix(4096)); return true }
            do { try handle?.write(contentsOf: data) } catch {
                failed = .local("the disk is full or not writable")
                return false
            }
            received += Int64(data.count)
            progress(offset + received, total)
            return true
        }

        func finish(_ e: Error?) {
            try? handle?.close()
            if let failed { return done(.failure(failed), etag) }
            if let e { return done(.failure((e as? URLError)?.code == .cancelled ? .cancelled : .network), etag) }
            if let error {
                let code = (try? JSONSerialization.jsonObject(with: error) as? [String: Any])?["e"] as? String
                return done(.failure(.host(code ?? "failed", status: status)), nil)
            }
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: file.path) { _ = try fm.replaceItemAt(file, withItemAt: part) } else { try fm.moveItem(at: part, to: file) }
                done(.success(file), etag)
            } catch {
                try? FileManager.default.removeItem(at: part)
                done(.failure(.local("couldn’t save it")), nil)
            }
        }
    }

    final class Delegate: NSObject, URLSessionDataDelegate {
        private let lock = NSLock()
        private var sent: [Int: (Int64) -> Void] = [:]
        private var receivers: [Int: Receiver] = [:]

        func onSent(_ t: URLSessionTask, _ f: @escaping (Int64) -> Void) {
            lock.lock(); sent[t.taskIdentifier] = f; lock.unlock()
        }

        func onReceive(_ t: URLSessionTask, _ r: Receiver) {
            lock.lock(); receivers[t.taskIdentifier] = r; lock.unlock()
        }

        private func receiver(_ t: URLSessionTask) -> Receiver? {
            lock.lock(); defer { lock.unlock() }
            return receivers[t.taskIdentifier]
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData _: Int64, totalBytesSent: Int64, totalBytesExpectedToSend _: Int64) {
            lock.lock(); let f = sent[task.taskIdentifier]; lock.unlock()
            f?(totalBytesSent)
        }

        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let r = receiver(dataTask), let h = response as? HTTPURLResponse else { return completionHandler(.allow) }
            completionHandler(r.start(h) ? .allow : .cancel)
        }

        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if let r = receiver(dataTask), !r.write(data) { dataTask.cancel() }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            sent[task.taskIdentifier] = nil
            let r = receivers.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            r?.finish(error)
        }
    }
}

/// Where things go when names are taken: "name (1).ext", "name (2).ext"…, like the host's
/// `exists=rename`.
public enum FileNames {
    public static func unique(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") ? name : (name as NSString).deletingPathExtension
        let suffix = stem == name ? "" : ".\(ext)"
        for n in 1... {
            let candidate = "\(stem) (\(n))\(suffix)"
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }

    /// A name from the host that is safe to put under a local folder: relative, and no part of it
    /// empty, `.` or `..` (a listing is data from the other computer; it mustn't write elsewhere).
    public static func isSafeRelative(_ name: String, nested: Bool) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0") else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard nested || parts.count == 1 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Joins a remote folder and a relative name with `/`.
    public static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
}
