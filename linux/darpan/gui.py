"""Darpan status window (GTK 4 + libadwaita): address, password, network sign-in and
connected devices. All slow calls run on a worker thread; the UI never blocks."""
import os
import shutil
import subprocess
import threading
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from . import auth, config, control, login_screen, tailscale, update  # noqa: E402

APP_ID = "dev.darpan.Darpan"


def _bg(fn, done=None):
    def run():
        try:
            res = fn()
        except Exception as e:  # surfaced in the UI, never crash the window
            res = e
        if done:
            GLib.idle_add(done, res)
    threading.Thread(target=run, daemon=True).start()


def _open(url):
    try:
        Gio.AppInfo.launch_default_for_uri(url, None)
    except GLib.Error:
        subprocess.Popen(["xdg-open", url])


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Darpan", default_width=480, default_height=680)
        self.cfg = config.load()
        self.reveal = False
        self.serve_url = None
        self.last = None

        self.toasts = Adw.ToastOverlay()
        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        self.update = Adw.Banner(button_label="Update")      # shown when APT knows a newer Darpan
        self.update.connect("button-clicked", self.on_update)
        view.add_top_bar(self.update)
        _bg(update.available, self._update_found)
        GLib.timeout_add_seconds(3600, self._check_update)     # the system refreshes APT's lists daily
        page = Adw.PreferencesPage()
        # First run: a few friendly steps instead of the settings (which stay one "Done" away).
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        self.stack.add_named(Gtk.Box(), "blank")            # until the first refresh knows which
        self.stack.add_named(page, "main")
        self._build_onboarding()
        self.onboarding = None               # decided on the first refresh: already set up or not
        self.signing_in = False
        self.publish_at = 0.0
        view.set_content(self.stack)
        self.toasts.set_child(view)
        self.set_content(self.toasts)

        # --- status
        g = Adw.PreferencesGroup()
        self.status = Adw.ActionRow(title="Checking…")
        self.status_icon = Gtk.Image.new_from_icon_name("content-loading-symbolic")
        self.status_icon.set_pixel_size(24)
        self.status.add_prefix(self.status_icon)
        self.status_btn = Gtk.Button(valign=Gtk.Align.CENTER, visible=False)
        self.status_btn.add_css_class("suggested-action")
        self.status_btn.connect("clicked", self.on_status_action)
        self.status.add_suffix(self.status_btn)
        g.add(self.status)
        page.add(g)

        # --- how to connect
        g = Adw.PreferencesGroup(title="Connect from another computer")
        self.addr = Adw.ActionRow(title="Address", subtitle="—", subtitle_selectable=True)
        self.addr.add_suffix(self._icon_button("edit-copy-symbolic", "Copy address", lambda *_: self._copy(self.serve_url)))
        g.add(self.addr)
        self.pw = Adw.ActionRow(title="Password", subtitle="•" * 12)
        self.pw_eye = self._icon_button("view-reveal-symbolic", "Show password", self.on_reveal)
        self.pw.add_suffix(self.pw_eye)
        self.pw.add_suffix(self._icon_button("edit-copy-symbolic", "Copy password", self.on_copy_password))
        change = Gtk.MenuButton(icon_name="document-edit-symbolic", valign=Gtk.Align.CENTER, tooltip_text="Change password")
        change.add_css_class("flat")
        menu = Gio.Menu()
        menu.append("Choose my own…", "win.set-password")
        menu.append("Generate a new one", "win.new-password")
        change.set_menu_model(menu)
        self.pw.add_suffix(change)
        g.add(self.pw)
        page.add(g)
        for name, cb in (("set-password", self.on_set_password), ("new-password", self.on_new_password)):
            a = Gio.SimpleAction.new(name, None)
            a.connect("activate", cb)
            self.add_action(a)

        # --- network
        g = Adw.PreferencesGroup(title="Private network",
                                 description="Tailscale links this computer and your devices end-to-end encrypted. "
                                             "Nothing is exposed to the internet.")
        self.net = Adw.ActionRow(title="Tailscale", subtitle="…")
        g.add(self.net)
        page.add(g)

        g = Adw.PreferencesGroup(title="After a restart")
        self.login = Adw.SwitchRow(title="Show the login screen",
                                   subtitle="Log in from your other device, with nobody at this computer",
                                   active=login_screen.on())
        if login_screen.others():
            self.login.set_subtitle("Other people log in here too: your account would see what they type "
                                    "at the login screen")
        self.login.connect("notify::active", self.on_login_screen)
        g.add(self.login)
        page.add(g)

        # --- sessions
        self.sessions = Adw.PreferencesGroup(title="Connected devices")
        self.none_row = Adw.ActionRow(title="Nobody is connected")
        self.none_row.add_css_class("dim-label")
        self.sessions.add(self.none_row)
        self.session_rows = []
        page.add(self.sessions)

        # --- about
        g = Adw.PreferencesGroup()
        self.enc = Adw.ActionRow(title="Video encoder", subtitle="…")
        g.add(self.enc)
        page.add(g)

        self.refresh()
        GLib.timeout_add_seconds(2, self.refresh)

    # ---------------------------------------------------------------- onboarding
    def _step(self, name, icon, title, description, *children):
        sp = Adw.StatusPage(icon_name=icon, title=title, description=description)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, halign=Gtk.Align.CENTER)
        for c in children:
            box.append(c)
        sp.set_child(box)
        self.stack.add_named(sp, name)
        return sp

    @staticmethod
    def _pill(label, cb):
        b = Gtk.Button(label=label, halign=Gtk.Align.CENTER)
        b.add_css_class("pill")
        b.add_css_class("suggested-action")
        b.connect("clicked", cb)
        return b

    @staticmethod
    def _note(markup):
        lb = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER, max_width_chars=46, use_markup=True)
        lb.set_markup(markup)
        lb.add_css_class("dim-label")
        return lb

    def _build_onboarding(self):
        self._step("welcome", "darpan", "Welcome to Darpan",
                   "Use this computer from your Mac or any browser.\nPrivate, and free.",
                   self._pill("Get started", self.on_get_started),
                   self._note("No account with us. You sign in with Google, Apple, GitHub or Microsoft through "
                              "Tailscale, which links your devices privately."))
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32)
        again = Gtk.Button(label="Open the sign-in page again", halign=Gtk.Align.CENTER)
        again.add_css_class("flat")
        again.connect("clicked", lambda *_: self.on_get_started(None))
        self._step("signin", "web-browser-symbolic", "Finish in your browser",
                   "Tailscale's sign-in page is open in your browser. Darpan carries on by itself when you're done.",
                   spinner, again)
        self._step("working", "network-workgroup-symbolic", "Almost there",
                   "Making this computer's secure address on your private network…",
                   Gtk.Spinner(spinning=True, width_request=32, height_request=32))
        self.https_url = None
        self.https_step = self._step("https", "channel-secure-symbolic", "One last click",
                                     "Tailscale asks once to allow secure addresses for your devices. Turn it on in "
                                     "the page that opens; Darpan finishes by itself.",
                                     self._pill("Open the page", lambda *_: self.https_url and _open(self.https_url)))
        self.ready_pw = Gtk.Label(selectable=True)
        self.ready_pw.add_css_class("title-1")
        self.ready_pw.add_css_class("monospace")
        pw_row = Gtk.Box(spacing=6, halign=Gtk.Align.CENTER)
        pw_row.append(self.ready_pw)
        pw_row.append(self._icon_button("edit-copy-symbolic", "Copy password", self.on_copy_password))
        self.ready_mac = self._note("")
        self.ready_addr = Gtk.Label(selectable=True, wrap=True, max_width_chars=46)
        self.ready_addr.add_css_class("dim-label")
        addr_row = Gtk.Box(spacing=4, halign=Gtk.Align.CENTER)
        addr_row.append(self.ready_addr)
        addr_row.append(self._icon_button("edit-copy-symbolic", "Copy address", lambda *_: self._copy(self.serve_url)))
        browser = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        browser.append(self._note("From a browser on another device:"))
        browser.append(addr_row)
        self._step("ready", "emblem-ok-symbolic", "You're set",
                   "Open Darpan on your Mac and sign in with the same account. Then click this computer and "
                   "enter this password:",
                   pw_row, self.ready_mac, browser, self._pill("Done", self.on_onboarding_done))

    @staticmethod
    def _mac_download():
        """The Mac app on the same GitHub releases this package updates from (its APT source)."""
        try:
            for line in open("/etc/apt/sources.list.d/darpan.sources"):
                if line.startswith("URIs:"):
                    return line.split(":", 1)[1].strip().rstrip("/") + "/Darpan.dmg"
        except OSError:
            pass
        return None

    def _onboard(self, st, ts, served):
        """Which step to show while setting up; publishes by itself once signed in."""
        state = ts.get("state")
        if state == "Running" and served:
            store = auth.AuthStore()
            self.ready_pw.set_label(store.visible_password() or "your own password")
            dmg = self._mac_download()
            self.ready_mac.set_markup('No Darpan on the Mac yet? <a href="%s">Download it</a>.'
                                      % GLib.markup_escape_text(dmg) if dmg else "")
            self.ready_mac.set_visible(bool(dmg))
            self.ready_addr.set_label(self.serve_url or "")
            self.stack.set_visible_child_name("ready")
        elif state == "Running":
            now = time.monotonic()
            if now >= self.publish_at:           # at most every 4 s, while Tailscale waits for the user
                self.publish_at = now + 4
                _bg(lambda: tailscale.serve(control.host_port(self.cfg["port"])), self._published)
            if self.stack.get_visible_child_name() != "https":
                self.stack.set_visible_child_name("working")
        elif self.signing_in:
            self.stack.set_visible_child_name("signin")
        else:
            self.stack.set_visible_child_name("welcome")

    def _published(self, res):
        if isinstance(res, Exception) or not self.onboarding:
            return False
        ok, msg = res
        if ok:
            self.refresh()
        elif msg.startswith("https://"):
            if self.https_url != msg:
                _open(msg)                       # once; the button opens it again
            self.https_url = msg
            self.stack.set_visible_child_name("https")
        else:
            self.https_step.set_description(msg)
            self.stack.set_visible_child_name("https")
        return False

    def on_get_started(self, _btn):
        self.signing_in = True
        self.stack.set_visible_child_name("signin")

        def start():
            if subprocess.run(["systemctl", "--user", "is-active", "--quiet", "darpan-net.service"]).returncode:
                subprocess.run(["systemctl", "--user", "start", "darpan-net.service", "darpan.service"])
                for _ in range(40):                  # the network's daemon takes a moment to answer
                    if tailscale.status() is not None:
                        break
                    time.sleep(0.25)
            return tailscale.login(config.hostname().lower())

        def opened(url):
            if isinstance(url, Exception):
                self.signing_in = False
                self.stack.set_visible_child_name("welcome")
                self._toast("Couldn't start signing in: %s" % url)
            elif url:
                _open(url)
            self.refresh()
            return False
        _bg(start, opened)

    def on_onboarding_done(self, _btn):
        self.onboarding = False
        self.stack.set_visible_child_name("main")

    # ---------------------------------------------------------------- helpers
    def _icon_button(self, icon, tip, cb):
        b = Gtk.Button(icon_name=icon, valign=Gtk.Align.CENTER, tooltip_text=tip)
        b.add_css_class("flat")
        b.connect("clicked", cb)
        return b

    def _toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=text, timeout=3))

    def _copy(self, text):
        if text:
            self.get_clipboard().set(text)
            self._toast("Copied")

    # ---------------------------------------------------------------- refresh
    def refresh(self):
        def collect():
            try:
                st = control.request("status")
            except OSError:
                st = None
            ts = tailscale.summary()
            served = ts.get("state") == "Running" and tailscale.serving(st["port"] if st else self.cfg["port"])
            return st, ts, served
        _bg(collect, self.apply)
        return True

    def apply(self, res):
        if isinstance(res, Exception):
            return False
        st, ts, served = res
        self.last = res
        if self.onboarding is None:
            self.onboarding = not (ts.get("state") == "Running" and served)
            if not self.onboarding:
                self.stack.set_visible_child_name("main")
        store = auth.AuthStore()
        visible = store.visible_password()
        self.pw.set_subtitle((visible if self.reveal else "•" * 12) if visible else
                             ("Your own password" if store.configured else "Not set"))
        self.pw_eye.set_visible(bool(visible))
        state = ts.get("state")
        self.serve_url = ts.get("url") if served else None
        self.addr.set_subtitle(self.serve_url or "Available after the steps above")
        if state == "Running":
            self.net.set_subtitle("Connected%s" % (" as " + ts["user"] if ts.get("user") else ""))
        elif state == "stopped":
            self.net.set_subtitle("Not running")
        else:
            self.net.set_subtitle(state)

        if st is None:
            self._status("dialog-warning-symbolic", "Remote access is off", "The host service is not running.", "Start")
        elif state == "stopped":
            self._status("dialog-warning-symbolic", "Private network is off", "Start it to accept connections.", "Start")
        elif state != "Running":
            self._status("network-offline-symbolic", "Sign in to finish setup",
                         "Use any Google, Microsoft, GitHub or Apple account — free.", "Sign in")
        elif not served:
            self._status("network-workgroup-symbolic", "Almost ready", "Publish the secure address on your network.", "Publish")
        else:
            n = len(st.get("sessions") or [])
            self._status("emblem-ok-symbolic", "Ready for remote connections",
                         "%d device%s connected" % (n, "" if n == 1 else "s") if n else "Waiting for a connection", None)
        if st:
            gpu = st.get("encoder")
            if st.get("restart_for_gpu"):
                self.enc.set_subtitle("Restart to use the GPU after the NVIDIA driver update")
            else:
                self.enc.set_subtitle(("NVENC hardware · " + gpu) if gpu else "Software (x264)")
            self._sessions(st.get("sessions") or [])
        if self.onboarding:
            self._onboard(st, ts, served)
        return False

    def _status(self, icon, title, sub, action):
        self.status_icon.set_from_icon_name(icon)
        self.status.set_title(title)
        self.status.set_subtitle(sub)
        self.status_btn.set_visible(bool(action))
        if action:
            self.status_btn.set_label(action)

    def _sessions(self, sessions):
        for r in self.session_rows:
            self.sessions.remove(r)
        self.session_rows = []
        self.none_row.set_visible(not sessions)
        for s in sessions:
            since = time.strftime("%H:%M", time.localtime(s["since"]))
            sub = "%s · since %s" % (s.get("user") or s["source"], since)
            if s.get("streaming"):
                sub += " · %d×%d" % (s["w"], s["h"])
            row = Adw.ActionRow(title=s["client"] or "Unknown device", subtitle=sub)
            row.add_prefix(Gtk.Image.new_from_icon_name("computer-symbolic"))
            b = Gtk.Button(label="Disconnect", valign=Gtk.Align.CENTER)
            b.add_css_class("destructive-action")
            b.connect("clicked", lambda _b, sid=s["sid"]: _bg(lambda: control.request("kick", sid=sid),
                                                               lambda _r: self.refresh() and False))
            row.add_suffix(b)
            self.sessions.add(row)
            self.session_rows.append(row)

    # ---------------------------------------------------------------- actions
    def on_status_action(self, btn):
        label = btn.get_label()
        if label == "Start":
            _bg(lambda: subprocess.run(["systemctl", "--user", "start", "darpan-net.service", "darpan.service"]),
                lambda _r: self.refresh() and False)
        elif label == "Sign in":
            btn.set_sensitive(False)

            def login():
                return tailscale.login(config.hostname().lower())

            def opened(url):
                btn.set_sensitive(True)
                if isinstance(url, Exception):
                    self._toast("Sign-in failed: %s" % url)
                elif url:
                    _open(url)
                    self._toast("Finish signing in in your browser")
                return False
            _bg(login, opened)
        elif label == "Publish":
            def publish():
                return tailscale.serve(control.host_port(self.cfg["port"]))

            def done(res):
                if isinstance(res, Exception):
                    self._toast("Failed: %s" % res)
                    return False
                ok, msg = res
                if ok:
                    self._toast("Published")
                elif msg.startswith("https://"):
                    _open(msg)
                    self._toast("Enable HTTPS for your tailnet in the browser, then press Publish again")
                else:
                    self._toast(msg[:120])
                self.refresh()
                return False
            _bg(publish, done)

    def _check_update(self):
        if self.update.get_sensitive():                        # not while one is being installed
            _bg(update.available, self._update_found)
        return True

    def _update_found(self, version):
        if isinstance(version, str):
            self.update.set_title("Darpan %s is available" % version)
        self.update.set_revealed(isinstance(version, str))

    def on_update(self, banner):
        banner.set_sensitive(False)
        banner.set_title("Updating…")

        def done(ok):
            darpan = shutil.which("darpan")
            if ok is True and darpan:
                os.execv(darpan, [darpan, "gui"])          # the new version's window
            banner.set_sensitive(True)
            _bg(update.available, self._update_found)
            if ok is not True:
                self._toast("Not updated")
        _bg(update.install, done)

    def on_login_screen(self, row, _pspec):
        want = row.get_active()
        if want == login_screen.on():
            return
        row.set_sensitive(False)

        def done(ok):
            row.set_sensitive(True)
            row.set_active(login_screen.on())       # cancelled: back as it was
            if ok is True and want:
                self._toast("From the next restart, Darpan shows the login screen")
        _bg(lambda: login_screen.turn(want), done)

    def on_reveal(self, *_):
        self.reveal = not self.reveal
        self.pw_eye.set_icon_name("view-conceal-symbolic" if self.reveal else "view-reveal-symbolic")
        if self.last:
            self.apply(self.last)

    def on_copy_password(self, *_):
        pw = auth.AuthStore().visible_password()
        if pw:
            self._copy(pw)
        else:
            self._toast("Your own password isn't stored — nothing to copy")

    def _changed(self):
        try:
            control.request("reload")
        except OSError:
            pass
        self.refresh()

    def on_new_password(self, *_):
        auth.AuthStore().generate()
        self.reveal = True
        self._changed()
        self._toast("New password generated")

    def on_set_password(self, *_):
        d = Adw.AlertDialog(heading="Choose a password", body="At least 8 characters. Devices that remembered the old one will ask again.")
        box = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        box.add_css_class("boxed-list")
        e1 = Adw.PasswordEntryRow(title="New password")
        e2 = Adw.PasswordEntryRow(title="Repeat")
        box.append(e1)
        box.append(e2)
        d.set_extra_child(box)
        d.add_response("cancel", "Cancel")
        d.add_response("save", "Save")
        d.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED)
        d.set_default_response("save")

        def resp(dialog, r):
            if r != "save":
                return
            a, b = e1.get_text(), e2.get_text()
            if len(a) < 8:
                self._toast("Too short — use at least 8 characters")
            elif a != b:
                self._toast("The passwords didn't match")
            else:
                auth.AuthStore().set_password(a)
                self.reveal = False
                self._changed()
                self._toast("Password changed")
        d.connect("response", resp)
        d.present(self)


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_activate(self):
        win = self.props.active_window or Window(self)
        win.present()


def main():
    config.ensure_dirs()
    GLib.set_prgname(APP_ID)          # WM_CLASS → matches dev.darpan.Darpan.desktop
    GLib.set_application_name("Darpan")
    return App().run([])
