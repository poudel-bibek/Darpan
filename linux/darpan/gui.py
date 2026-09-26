"""Darpan status window (GTK 4 + libadwaita): address, password, network sign-in and
connected devices. All slow calls run on a worker thread; the UI never blocks."""
import os
import subprocess
import threading
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from . import auth, config, control, tailscale  # noqa: E402

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
        page = Adw.PreferencesPage()
        view.set_content(page)
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
