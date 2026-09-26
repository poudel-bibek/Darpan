"""Darpan at the login screen: after a restart, connect and log in from your other device.
Turned on per user, as root, by /opt/darpan/login-screen-setup (through pkexec)."""
import os
import pwd
import subprocess

DIR = "/etc/darpan/login-screen.d"
SETUP = "/opt/darpan/login-screen-setup"


def on():
    return os.path.exists(os.path.join(DIR, pwd.getpwuid(os.getuid()).pw_name))


def turn(enable):
    """Asks for the password (polkit). True once done."""
    if subprocess.run(["pkexec", SETUP, "on" if enable else "off"]).returncode:
        return False
    # now rather than from the next boot: Darpan's network stays up after you log out
    subprocess.run(["systemctl", "--user", "start" if enable else "stop", "darpan-login-screen.target"])
    return True
