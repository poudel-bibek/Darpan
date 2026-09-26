import AppKit
import DarpanCore
import SwiftUI

protocol ConnectHandler: AnyObject {
    func connect(to address: HostAddress, proxy: SOCKSProxy?, password: String?, saved: SavedKey?, remember: Bool?)
    func cancelConnect()
}

/// State of the connect window.
final class ConnectModel: ObservableObject {
    @Published var address = "" { didSet { if address != oldValue { refreshSavedKey() } } }
    @Published var password = ""
    @Published private(set) var connecting = false
    @Published private(set) var message = ""
    @Published private(set) var isError = false
    @Published private(set) var hasSavedKey = false
    @Published private(set) var showTailscaleHint = false
    /// Seconds until the remote computer accepts another attempt.
    @Published private(set) var countdown = 0
    /// Bumped to move the focus to the password field.
    @Published private(set) var focusPassword = 0
    /// The computer picked in the list that still needs its password.
    @Published private(set) var selected: String?

    weak var handler: ConnectHandler?
    private let settings = Settings.shared
    private var failure: Client.Failure?
    private var timer: Timer?
    /// Identifies the current connect attempt, so a late tailnet callback from a cancelled one is ignored.
    private var attempt = 0
    /// The current attempt got as far as creating a session (only then does Cancel end one).
    private var launched = false

    init() {
        address = settings.hosts.first ?? ""
        refreshSavedKey()
    }

    /// At launch: DARPAN_URL (+ DARPAN_PASSWORD, never stored) for testing, otherwise the last
    /// computer if its sign-in is saved.
    func autoConnect(environment env: [String: String]) {
        if let url = env["DARPAN_URL"], !url.isEmpty {
            address = url
            if let pw = env["DARPAN_PASSWORD"], !pw.isEmpty {
                password = pw
                connect(remember: nil, keychain: false)     // a test run: leave saved sign-ins alone
                return
            }
        }
        #if DEBUG
        // Test builds never read a saved sign-in on their own: each rebuilt binary would make
        // macOS ask for Keychain access.
        return
        #else
        if hasSavedKey { connect() }
        #endif
    }

    /// After a restart the remote computer answers before its screen is ready; the client retries.
    func hostStarting(_ name: String) {
        guard connecting else { return }
        show("\(name) is starting up. Darpan connects as soon as it’s ready.", error: false)
    }

    /// `keychain` false: neither save nor delete a sign-in (environment-driven test runs).
    func connect(remember: Bool? = nil, keychain: Bool = true) {
        guard !connecting, countdown == 0 else { return }
        let a: HostAddress
        do {
            a = try HostAddress(parsing: address)
        } catch {
            show((error as? HostAddress.Problem)?.description ?? "That doesn’t look like an address.", error: true)
            return
        }
        let pw = password.isEmpty ? nil : password
        let saved = pw == nil ? Keychain.load(a.origin) : nil
        guard pw != nil || saved != nil else {
            refreshSavedKey()
            show("Enter the password.", error: true)
            focusPassword += 1
            return
        }
        let keep: Bool? = keychain ? (remember ?? settings.remember) : nil
        #if DEBUG
        // DARPAN_DEBUG_SOCKS=host:port:user:password tests the proxy path without a tailnet.
        if let spec = ProcessInfo.processInfo.environment["DARPAN_DEBUG_SOCKS"]?.split(separator: ":").map(String.init),
           spec.count == 4, let port = UInt16(spec[1]) {
            begin(a, proxy: SOCKSProxy(host: spec[0], port: port, username: spec[2], password: spec[3]),
                  password: pw, saved: saved, remember: keep)
            return
        }
        #endif
        guard settings.network == .builtIn, !HostAddress.isLoopback(a.host) else {
            begin(a, proxy: nil, password: pw, saved: saved, remember: keep)
            return
        }
        // Built-in network: the node has to be up and signed in first.
        let net = Tailnet.shared
        attempt += 1
        let mine = attempt
        connecting = true
        show("Joining your private network…", error: false)
        net.start { [weak self] proxy in
            guard let self, self.connecting, self.attempt == mine else { return }
            guard let proxy else {
                self.connecting = false
                if case .failed(let m) = net.phase { self.show(m, error: true) }
                return
            }
            net.settle { phase in
                guard self.connecting, self.attempt == mine else { return }
                switch phase {
                case .running:
                    self.begin(a, proxy: proxy, password: pw, saved: saved, remember: keep)
                case .needsLogin:
                    self.connecting = false
                    self.show("Sign in to your private network first (above).", error: true)
                case .failed(let m):
                    self.connecting = false
                    self.show(m, error: true)
                case .starting, .off:
                    self.connecting = false
                    self.show("Your private network isn’t ready yet. Check this Mac’s internet connection, then try again.", error: true)
                }
            }
        }
    }

    private func begin(_ a: HostAddress, proxy: SOCKSProxy?, password pw: String?, saved: SavedKey?, remember: Bool?) {
        password = ""
        address = a.origin
        connecting = true
        showTailscaleHint = false
        failure = nil
        show("Connecting to \(a.shortName)…", error: false)
        launched = true
        handler?.connect(to: a, proxy: proxy, password: pw, saved: saved, remember: remember)
    }

    /// A click in the computer list: connect at once if its sign-in is saved, else ask for the password.
    func open(_ origin: String) {
        address = origin
        password = ""
        if Keychain.contains(origin) {
            selected = nil
            connect()
        } else {
            selected = origin
            show("", error: false)
            focusPassword += 1
        }
    }

    func cancel() {
        attempt += 1
        connecting = false
        show("", error: false)
        // Still in the private-network preflight: nothing to cancel yet, and a session that
        // is already open (New Connection… while connected) must keep running.
        if launched { handler?.cancelConnect() }
        launched = false
    }

    /// The session ended (or never started). `failure` nil: the user disconnected or cancelled.
    func ended(_ failure: Client.Failure?, wasConnected: Bool) {
        connecting = false
        launched = false
        refreshSavedKey()
        guard let failure else {
            show(wasConnected ? "Disconnected." : "", error: false)
            return
        }
        self.failure = failure
        showTailscaleHint = { if case .unreachable = failure { return true } else { return false } }()
        countdown = failure.retryAfter ?? 0
        timer?.invalidate()
        if countdown > 0 {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard let self else { return t.invalidate() }
                self.countdown = max(0, self.countdown - 1)
                if self.countdown == 0 { t.invalidate() }
                self.showFailure()
            }
        }
        showFailure()
        if failure.wantsPassword {
            selected = address                              // the list shows the password field for it
            focusPassword += 1
        }
    }

    func connected() {
        connecting = false
        launched = false
        show("", error: false)
    }

    func forgetSavedKey() {
        guard let a = try? HostAddress(parsing: address) else { return }
        Keychain.delete(a.origin)
        refreshSavedKey()
    }

    func removeFromList(_ origin: String) {
        Keychain.delete(origin)
        settings.forgetHost(origin)
        refreshSavedKey()
    }

    private func showFailure() {
        guard let f = failure else { return }
        switch f {
        case .locked:
            show(countdown > 0 ? "Too many attempts. Try again in \(countdown) s." : "You can try again now.", error: countdown > 0)
        case .wrongPassword(let r) where r > 0:
            show(countdown > 0 ? "Wrong password. Locked for \(countdown) s." : "Wrong password.", error: true)
        case .unreachable(let detail) where settings.network == .builtIn:
            show("Could not reach the remote computer over your private network. Is it on, with Darpan running?"
                 + (detail.map { "\n(\($0))" } ?? ""), error: true)
        case .kicked(let reason?) where !reason.isEmpty && reason != "disconnected by host":
            show("\(f.description): \(reason)", error: true)
        default:
            show(f.description, error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }

    private func refreshSavedKey() {
        hasSavedKey = (try? HostAddress(parsing: address)).map { Keychain.contains($0.origin) } ?? false
    }
}

struct ConnectView: View {
    @ObservedObject var model: ConnectModel
    @ObservedObject var discovery: Discovery
    @ObservedObject var settings = Settings.shared
    @ObservedObject var net = Tailnet.shared
    @ObservedObject var updater = Updater.shared
    @FocusState private var focus: Field?
    @State private var manual = false
    /// "Get started" was clicked: open the Tailscale sign-in as soon as its link exists.
    @State private var signInPending = false

    private enum Field { case address, password }

    /// First launch: nothing signed in, nothing used yet.
    private var showWelcome: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DARPAN_DEBUG_WELCOME"] != nil { return true }   // for screenshots
        #endif
        return !settings.welcomed && settings.network == .builtIn && settings.hosts.isEmpty && !Tailnet.hasState
    }

    var body: some View {
        Group {
            if showWelcome { welcome } else { main }
        }
        .onChange(of: net.phase) {
            if signInPending, case .needsLogin(let url?, _) = net.phase {
                signInPending = false
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - first launch

    private var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Welcome to Darpan").font(.system(size: 22, weight: .semibold)).padding(.top, 6)
            Text("Your Linux computer, on this Mac.")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 12) {
                step(1, "On the Linux computer, open Darpan and click **Get started**.")
                step(2, "Here, sign in with the same account: Google, Apple, GitHub or Microsoft.")
                step(3, "Click your computer. The first time, type the password shown in the Darpan window there.")
            }
            .padding(.top, 20)
            Button {
                settings.welcomed = true
                signInPending = true
                net.start()
                if case .needsLogin(let url?, _) = net.phase { signInPending = false; NSWorkspace.shared.open(url) }
            } label: {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .padding(.top, 22)
            Text("The only setup is a free Tailscale account. There’s no account with us.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(28)
        .frame(width: 380)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "\(n).circle.fill").font(.system(size: 16)).foregroundStyle(Color.accentColor)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - after that

    private var main: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Darpan").font(.system(size: 20, weight: .semibold)).padding(.top, 4)
            Group {
                if settings.network == .builtIn && net.phase != .running && !manual {
                    signIn
                } else if settings.network == .builtIn && !manual {
                    computers
                } else {
                    manualEntry
                }
            }
            .padding(.top, 18)

            if !model.message.isEmpty {
                Text(model.message)
                    .font(.system(size: 12))
                    .foregroundStyle(model.isError ? Color(nsColor: .systemRed) : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            if model.connecting {
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).padding(.top, 8)
            }
            if model.showTailscaleHint && settings.network == .system { tailscaleHint.padding(.top, 8) }
            update
            footer.padding(.top, 18)
        }
        .padding(24)
        .frame(width: 360)
        .onChange(of: model.focusPassword) { focus = .password }
        .onChange(of: settings.network) { if settings.network == .builtIn { net.start() } }
    }

    // MARK: - not signed in to the private network

    @ViewBuilder private var signIn: some View {
        VStack(spacing: 12) {
            switch net.phase {
            case .needsLogin(let url, let again):
                Text(again ? "Your Tailscale sign-in on this Mac has ended. Sign in again to reach your computers."
                           : "Darpan reaches your Linux computers over Tailscale, your private network. Sign in with the same account you use on them.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button { if let url { NSWorkspace.shared.open(url) } } label: {
                    Text(again ? "Sign in again" : "Sign in with Tailscale").frame(maxWidth: .infinity)
                }
                .controlSize(.large).keyboardShortcut(.defaultAction).disabled(url == nil)
                Text("Tip: in the Tailscale admin console, turn off key expiry for this Mac so it stays signed in.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            case .failed(let m):
                Text(m).font(.system(size: 12)).foregroundStyle(Color(nsColor: .systemRed))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { net.start() }.controlSize(.large)
            case .starting, .off, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Joining your private network…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(height: 60)
            }
        }
    }

    // MARK: - the computer list

    private var computers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR COMPUTERS").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            if discovery.computers.isEmpty {
                VStack(spacing: 8) {
                    if discovery.scanned {
                        Text("No computers with Darpan found yet.").font(.system(size: 13))
                        Text("Open Darpan on your Linux computer and click Get started, with the same account. It shows up here by itself.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Looking for your computers…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(discovery.computers.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider().padding(.leading, 30) }
                        row(c)
                        if model.selected == c.origin && !model.hasSavedKey { passwordEntry.padding([.horizontal, .bottom], 12) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func row(_ c: Discovery.Computer) -> some View {
        let saved = Keychain.contains(c.origin)
        let busy = model.connecting && model.address == c.origin
        return Button { model.open(c.origin) } label: {
            HStack(spacing: 10) {
                Circle().fill(c.online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.system(size: 13, weight: .medium))
                    Text(!c.online ? "Offline" : saved ? "Ready to connect" : "Needs the password once")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.connecting || model.countdown > 0)
        .help(c.origin)
        .contextMenu {
            Button("Remove from List") { model.removeFromList(c.origin) }
        }
    }

    private var passwordEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Password", text: $model.password)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .password)
                .onSubmit { model.connect() }
            Text("The password shown in the Darpan window on the Linux computer.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Remember on this Mac", isOn: $settings.remember).toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                Button("Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.password.isEmpty || model.connecting || model.countdown > 0)
            }
        }
        .onAppear { focus = .password }
    }

    // MARK: - typing an address

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Address").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("machine.tailnet.ts.net", text: $model.address)
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .address).disabled(model.connecting)
                Text("Shown in Darpan on your Linux computer, or run `darpan status` there.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Password").font(.system(size: 12)).foregroundStyle(.secondary)
                SecureField(model.hasSavedKey ? "Saved on this Mac" : "", text: $model.password)
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .password).disabled(model.connecting)
                Text("Shown in the Darpan window on the Linux computer.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("Remember on this Mac", isOn: $settings.remember).toggleStyle(.checkbox).font(.system(size: 12))
            Button { model.connect() } label: { Text("Connect").frame(maxWidth: .infinity) }
                .controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(model.connecting || model.countdown > 0)
        }
        .onAppear { focus = model.address.isEmpty ? .address : .password }
    }

    // MARK: - a new version

    @ViewBuilder private var update: some View {
        switch updater.state {
        case .available(let m):
            HStack {
                Text("Darpan \(m.version) is available").font(.system(size: 12))
                Spacer()
                Button("Install & Relaunch") { updater.install() }.controlSize(.small)
            }
            .padding(.top, 18)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 18)
        default:
            EmptyView()
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack {
            if settings.network == .builtIn {
                Button(manual ? "Your computers" : "Other address…") { manual.toggle() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            Spacer()
            Menu {
                Picker("Network", selection: $settings.network) {
                    Text("Built-in Tailscale").tag(NetworkMode.builtIn)
                    Text("This Mac’s network (Tailscale app, VPN…)").tag(NetworkMode.system)
                }
                .pickerStyle(.inline)
                if settings.network == .builtIn, let account = net.account {
                    Divider()
                    Text("Signed in as \(account)")
                }
                if model.hasSavedKey {
                    Divider()
                    Button("Forget Saved Password for This Computer") { model.forgetSavedKey() }
                }
                Divider()
                Toggle("Check for Updates Automatically", isOn: $settings.checkUpdates)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Network and account")
        }
    }

    private var tailscaleHint: some View {
        let app = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        return VStack(spacing: 8) {
            Text("Both computers must be signed in to the same Tailscale network, with Tailscale running.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(app == nil ? "Get Tailscale" : "Open Tailscale") {
                if let app {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
                }
            }
        }
    }
}

final class ConnectWindowController: NSWindowController {
    let model = ConnectModel()
    private let discovery = Discovery()

    init() {
        let host = NSHostingController(rootView: ConnectView(model: model, discovery: discovery))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = AppInfo.name
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isRestorable = false
        w.tabbingMode = .disallowed
        super.init(window: w)
        w.center()
        // Tailnet status is polled only while this window is on screen.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w,
                                               queue: .main) { [weak self] _ in self?.visibilityChanged() }
    }

    private var watching = false

    private func visibilityChanged() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        guard visible != watching else { return }
        watching = visible
        if visible {
            if Settings.shared.network == .builtIn { Tailnet.shared.start() }
            Tailnet.shared.watch()
            discovery.start()
        } else {
            Tailnet.shared.unwatch()
            discovery.stop()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

