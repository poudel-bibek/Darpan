import AppKit
import DarpanCore
import SwiftUI

protocol ConnectHandler: AnyObject {
    func connect(to address: HostAddress, password: String?, saved: SavedKey?, remember: Bool)
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

    weak var handler: ConnectHandler?
    private let settings = Settings.shared
    private var failure: Client.Failure?
    private var timer: Timer?

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
                connect(remember: false)
                return
            }
        }
        if hasSavedKey { connect() }
    }

    func connect(remember: Bool? = nil) {
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
        password = ""
        address = a.origin
        connecting = true
        showTailscaleHint = false
        failure = nil
        show("Connecting to \(a.shortName)…", error: false)
        handler?.connect(to: a, password: pw, saved: saved, remember: remember ?? settings.remember)
    }

    func cancel() {
        handler?.cancelConnect()
    }

    /// The session ended (or never started). `failure` nil: the user disconnected or cancelled.
    func ended(_ failure: Client.Failure?, wasConnected: Bool) {
        connecting = false
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
        if failure.wantsPassword { focusPassword += 1 }
    }

    func connected() {
        connecting = false
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
    @ObservedObject var settings = Settings.shared
    @FocusState private var focus: Field?

    private enum Field { case address, password }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
            Text("Darpan").font(.system(size: 22, weight: .semibold)).padding(.top, 6)
            Text("Your Linux desktop, on this Mac").foregroundStyle(.secondary).padding(.top, 2)

            VStack(alignment: .leading, spacing: 12) {
                labeled("Address") {
                    HStack(spacing: 6) {
                        TextField("machine.tailnet.ts.net", text: $model.address)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .address)
                            .disabled(model.connecting)
                        if !settings.hosts.isEmpty { hostsMenu }
                    }
                }
                labeled("Password") {
                    SecureField(model.hasSavedKey ? "Saved on this Mac" : "", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .password)
                        .disabled(model.connecting)
                }
                Toggle("Remember on this Mac", isOn: $settings.remember)
                    .toggleStyle(.checkbox)
                    .disabled(model.connecting)
            }
            .padding(.top, 20)

            Button {
                model.connecting ? model.cancel() : model.connect()
            } label: {
                HStack(spacing: 8) {
                    if model.connecting { ProgressView().controlSize(.small) }
                    Text(model.connecting ? "Cancel" : "Connect")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(model.connecting ? .cancelAction : .defaultAction)
            .disabled(!model.connecting && model.countdown > 0)
            .padding(.top, 18)

            Text(model.message)
                .font(.system(size: 12))
                .foregroundStyle(model.isError ? Color(nsColor: .systemRed) : .secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32)
                .padding(.top, 10)

            if model.showTailscaleHint { tailscaleHint.padding(.top, 4) }
        }
        .padding(28)
        .frame(width: 360)
        .onAppear { focus = model.address.isEmpty ? .address : .password }
        .onChange(of: model.focusPassword) { _ in focus = .password }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            content()
        }
    }

    private var hostsMenu: some View {
        Menu {
            ForEach(settings.hosts, id: \.self) { h in
                Button(h.replacingOccurrences(of: "https://", with: "")) { model.address = h }
            }
            Divider()
            if model.hasSavedKey {
                Button("Forget Saved Sign-in") { model.forgetSavedKey() }
            }
            if let current = (try? HostAddress(parsing: model.address))?.origin, settings.hosts.contains(current) {
                Button("Remove from List") { model.removeFromList(current) }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent computers")
        .disabled(model.connecting)
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

    init() {
        let host = NSHostingController(rootView: ConnectView(model: model))
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
