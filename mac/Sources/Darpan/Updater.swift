import AppKit
import DarpanCore
import Security

/// Updates from the GitHub releases: at most once a day, and only while the app runs, fetch the
/// signed manifest (`releases/latest/download/darpan-mac.json` and `.sig`). A newer version is
/// offered in the connect window; installing downloads the DMG, checks its SHA-256 against the
/// manifest, checks the new app's code signature, replaces this bundle and relaunches. When the
/// bundle can't be replaced (not writable, or run from a translocated copy), the verified DMG is
/// opened instead.
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case available(UpdateManifest)
        case installing
        case failed(String)
    }

    @Published private(set) var state = State.idle

    /// Ed25519, raw 32 bytes: the release key's public half (the private half never leaves the
    /// release machine).
    private static let publicKey = Data(base64Encoded: "25WwdShAmjlKpC4Y0JyLHxjEPnF5YsFf09FTXDg9G4w=")!
    private static let interval: TimeInterval = 24 * 3600
    private static let lastCheckKey = "updateLastCheck"

    /// "owner/name", written into Info.plist by build.sh; nil in development builds (no updates).
    private let repo = Bundle.main.object(forInfoDictionaryKey: "DarpanRepository") as? String
    private let settings = Settings.shared
    private var timer: Timer?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private init() {}

    /// Schedules the daily check (the first one is due a day after the last).
    func start() {
        timer?.invalidate()
        timer = nil
        #if DEBUG
        // DARPAN_DEBUG_UPDATE_DMG=<Darpan.dmg>: install that image as if it had been downloaded.
        if let dmg = ProcessInfo.processInfo.environment["DARPAN_DEBUG_UPDATE_DMG"], state == .idle {
            state = .installing
            let delay = Double(ProcessInfo.processInfo.environment["DARPAN_DEBUG_UPDATE_DELAY"] ?? "") ?? 0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                let r = Self.replaceBundle(from: URL(fileURLWithPath: dmg))
                FileHandle.standardError.write(Data("[update] \(r)\n".utf8))
                DispatchQueue.main.async { if case .success(let app?) = r { self.relaunch(app) } }
            }
            return
        }
        // DARPAN_DEBUG_UPDATE_OFFER=<version>: show the update dialog for a made-up release.
        if let v = ProcessInfo.processInfo.environment["DARPAN_DEBUG_UPDATE_OFFER"], state == .idle {
            let m = UpdateManifest(version: v, build: 99, url: URL(string: "https://github.com/x/y/releases/download/v\(v)/Darpan.dmg")!,
                                   sha256: String(repeating: "0", count: 64), minMacOS: "14.0")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.state = .available(m); self.offer(m, manual: false) }
            return
        }
        #endif
        guard repo != nil, settings.checkUpdates else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let due = max(0, last + Self.interval - Date().timeIntervalSince1970)
        let t = Timer(timeInterval: max(due, 5), repeats: false) { [weak self] _ in self?.check(manual: false) }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// `manual`: from the menu, so "you're up to date" and errors are shown too.
    func check(manual: Bool) {
        guard let repo else {
            if manual { alert("Updates aren’t available in this build.") }
            return
        }
        if case .installing = state { return }
        state = .checking
        let base = URL(string: "https://github.com/\(repo)/releases/latest/download/")!
        fetch(base.appendingPathComponent("darpan-mac.json")) { json in
            self.fetch(base.appendingPathComponent("darpan-mac.json.sig")) { sig in
                DispatchQueue.main.async { self.checked(json: json, sig: sig, repo: repo, manual: manual) }
            }
        }
    }

    private func checked(json: Data?, sig: Data?, repo: String, manual: Bool) {
        defer {
            // An offered update isn't stamped: the next launch offers it again, in case it went
            // unseen (a saved computer connects at launch and hides the connect window).
            // Found one: no more checks this launch (it stays offered). Otherwise the next in a day.
            if case .available = state {} else {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                start()
            }
        }
        guard let json, let sig else {
            state = .idle
            if manual { alert("Couldn’t check for updates. Check the internet connection and try again.") }
            return
        }
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        do {
            let m = try UpdateManifest.verify(json: json, signature: sig, publicKey: Self.publicKey, repo: repo,
                                              currentVersion: DarpanVersion.string, currentBuild: build,
                                              macOS: ProcessInfo.processInfo.operatingSystemVersion)
            state = .available(m)
            offer(m, manual: manual)
        } catch UpdateManifest.Problem.notNewer {
            state = .idle
            if manual { alert("Darpan \(DarpanVersion.string) is the latest version.") }
        } catch UpdateManifest.Problem.macOS {
            state = .idle
            if manual { alert("A newer Darpan needs a newer version of macOS.") }
        } catch {
            state = .idle
            if manual { alert("The update information couldn’t be verified, so nothing was installed.") }
        }
    }

    /// Versions already offered in a dialog this launch ("Later" isn't asked again until relaunch).
    private var offered = Set<String>()

    /// A dialog on the front window: install now, or later (the connect window and the Darpan
    /// menu keep offering it).
    private func offer(_ m: UpdateManifest, manual: Bool) {
        guard manual || !offered.contains(m.version) else { return }
        // A background check never jumps in front of another app: it waits until Darpan is active.
        if !manual && !NSApp.isActive {
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                if let token { NotificationCenter.default.removeObserver(token) }
                if case .available(let now) = self?.state, now == m { self?.offer(m, manual: false) }
            }
            return
        }
        offered.insert(m.version)
        let a = NSAlert()
        a.messageText = "Darpan \(m.version) is available"
        a.informativeText = "You have \(DarpanVersion.string). Darpan installs it and relaunches."
        let install = a.addButton(withTitle: "Install & Relaunch")
        let later = a.addButton(withTitle: "Later")
        if !manual {
            // Keystrokes meant for the remote computer must not install: no Return default.
            install.keyEquivalent = ""
            later.keyEquivalent = "\u{1b}"
        }
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .alertFirstButtonReturn { self?.install(m) }
        }
        if let w = NSApp.keyWindow ?? NSApp.mainWindow, w.attachedSheet == nil {
            a.beginSheetModal(for: w, completionHandler: answer)
        } else {
            if manual { NSApp.activate(ignoringOtherApps: true) }
            answer(a.runModal())
        }
    }

    // MARK: - installing

    func install() {
        guard case .available(let m) = state else { return }
        install(m)
    }

    private func install(_ m: UpdateManifest) {
        if case .installing = state { return }
        state = .installing
        session.downloadTask(with: m.url) { file, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            var dmg: URL?
            if ok, let file {
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent("Darpan-\(m.version).dmg")
                try? FileManager.default.removeItem(at: keep)
                if (try? FileManager.default.moveItem(at: file, to: keep)) != nil { dmg = keep }
            }
            let result: Result<URL?, InstallError>
            if let dmg {
                result = (try? UpdateManifest.sha256(of: dmg)) == m.sha256 ? Self.replaceBundle(from: dmg) : .failure(.verify)
                if case .failure = result { try? FileManager.default.removeItem(at: dmg) }
            } else {
                result = .failure(.download)
            }
            DispatchQueue.main.async { self.finish(m, dmg: dmg, result) }
        }.resume()
    }

    private enum InstallError: Error {
        case download, verify, mount
    }

    private func finish(_ m: UpdateManifest, dmg: URL?, _ result: Result<URL?, InstallError>) {
        switch result {
        case .success(let app?):
            if let dmg { try? FileManager.default.removeItem(at: dmg) }
            relaunch(app)
        case .success(nil):
            // Can't replace this copy: hand the verified disk image to the user.
            state = .available(m)
            if let dmg { NSWorkspace.shared.open(dmg) }
            alert("Drag Darpan to Applications to finish updating to \(m.version).")
        case .failure(let e):
            state = .available(m)
            switch e {
            case .download: alert("The update couldn’t be downloaded. Try again later.")
            case .verify: alert("The downloaded update didn’t match its signature, so nothing was installed.")
            case .mount: alert("The update couldn’t be opened, so nothing was installed.")
            }
        }
    }

    /// Mounts the verified DMG and puts its Darpan.app in place of this one. Returns the app to
    /// relaunch, nil if this copy can't be replaced, or an error (nothing was changed).
    private static func replaceBundle(from dmg: URL) -> Result<URL?, InstallError> {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard !current.path.contains("/AppTranslocation/"), fm.isWritableFile(atPath: parent.path),
              fm.isWritableFile(atPath: current.path) else { return .success(nil) }
        let mount = fm.temporaryDirectory.appendingPathComponent("darpan-update-\(UUID().uuidString)")
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]) else {
            return .failure(.mount)
        }
        defer {
            let ok = run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            #if DEBUG
            FileHandle.standardError.write(Data("[update] detach \(ok)\n".utf8))
            #endif
            try? fm.removeItem(at: mount)
        }
        let source = mount.appendingPathComponent("Darpan.app")
        guard let staging = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true) else {
            return .success(nil)
        }
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("Darpan.app")
        guard (try? fm.copyItem(at: source, to: staged)) != nil else { return .failure(.mount) }
        guard signatureMatches(staged) else { return .failure(.verify) }
        guard (try? fm.replaceItemAt(current, withItemAt: staged)) != nil else { return .success(nil) }
        return .success(current)
    }

    /// The new app's signature is valid, and it satisfies this app's designated requirement when
    /// that names a certificate (an ad-hoc signature's requirement is its own hash, which no
    /// other build can meet; the manifest's signature is the check then).
    private static func signatureMatches(_ app: URL) -> Bool {
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else { return false }
        let strict = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var me: SecCode?
        var req: SecRequirement?
        var info: CFDictionary?
        var myStatic: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic,
              SecCodeCopySigningInformation(myStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return false }
        let flags = ((info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let adhoc = flags & 0x2 != 0            // kSecCodeSignatureAdhoc
        if !adhoc {
            guard SecCodeCopyDesignatedRequirement(myStatic, [], &req) == errSecSuccess else { return false }
        }
        return SecStaticCodeCheckValidity(newCode, strict, req) == errSecSuccess
    }

    private func relaunch(_ app: URL) {
        // A shell waits for this process to exit, then opens the new copy.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
        // The new copy is in place: this one must go. Quit normally (from the run loop, not from
        // inside a queue block), and if that hasn't happened within 10 s, leave anyway.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { _exit(0) }
        RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
    }

    // MARK: - helpers

    private func fetch(_ url: URL, _ done: @escaping (Data?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            done((response as? HTTPURLResponse)?.statusCode == 200 && (data?.count ?? 0) < 64 << 10 ? data : nil)
        }.resume()
    }

    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }
}
