"""Password store, challenge-response verification and brute-force protection.

The password never crosses the network: the host stores only PBKDF2(password, salt) and
the client proves knowledge of it by HMAC-ing a fresh random nonce (PROTOCOL.md §2).
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import time
import unicodedata

from . import config

ITERATIONS = 200_000
LABEL = b"darpan-auth-v1"
_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"   # no 0/o/1/l look-alikes


def derive(password, salt, iterations=ITERATIONS):
    pw = unicodedata.normalize("NFC", password).encode()
    return hashlib.pbkdf2_hmac("sha256", pw, salt, iterations, 32)


def generate_password():
    """12 random characters (60 bits) in easy-to-type groups: k7mq-4xrt-9pzw."""
    s = "".join(secrets.choice(_ALPHABET) for _ in range(12))
    return "-".join(s[i:i + 4] for i in range(0, 12, 4))


class AuthStore:
    def __init__(self):
        self.path = os.path.join(config.config_dir(), "auth.json")
        self.shown_path = os.path.join(config.config_dir(), "password.txt")
        self.salt = self.key = None
        self.iterations = ITERATIONS
        self.reload()

    def reload(self):
        try:
            with open(self.path) as f:
                d = json.load(f)
            self.salt = base64.b64decode(d["salt"])
            self.key = base64.b64decode(d["key"])
            self.iterations = int(d["iter"])
        except (FileNotFoundError, KeyError, ValueError):
            self.salt = self.key = None

    @property
    def configured(self):
        return self.key is not None

    def set_password(self, password, keep_visible=False):
        if len(password) < 8:
            raise ValueError("password must be at least 8 characters")
        salt = os.urandom(16)
        key = derive(password, salt)
        config.write_private(self.path, json.dumps({
            "salt": base64.b64encode(salt).decode(), "iter": ITERATIONS,
            "key": base64.b64encode(key).decode(), "set": int(time.time())}))
        if keep_visible:
            config.write_private(self.shown_path, password + "\n")
        else:
            try:
                os.unlink(self.shown_path)
            except FileNotFoundError:
                pass
        self.reload()

    def generate(self):
        pw = generate_password()
        self.set_password(pw, keep_visible=True)
        return pw

    def visible_password(self):
        """The auto-generated password, if the user hasn't replaced it with their own."""
        try:
            with open(self.shown_path) as f:
                return f.read().strip()
        except FileNotFoundError:
            return None

    def verify(self, nonce, proof_b64):
        if not self.configured:
            return False
        try:
            proof = base64.b64decode(proof_b64, validate=True)
        except (ValueError, TypeError):
            return False
        expected = hmac.new(self.key, LABEL + nonce, hashlib.sha256).digest()
        return hmac.compare_digest(expected, proof)


class RateLimiter:
    """Per-source lockout after repeated failures, plus a global circuit breaker."""

    PER_SOURCE = 5          # failures before a source is locked out
    BASE_LOCK = 30          # seconds, doubles with every further failure
    MAX_LOCK = 3600
    GLOBAL_WINDOW = 600
    GLOBAL_MAX = 30

    def __init__(self):
        self.sources = {}   # source -> [consecutive failures, locked_until]
        self.recent = []    # timestamps of failures (all sources)
        self.global_until = 0.0
        self.global_level = 0

    def retry_after(self, source):
        now = time.monotonic()
        wait = max(0.0, self.global_until - now)
        st = self.sources.get(source)
        if st:
            wait = max(wait, st[1] - now)
        return int(wait + 0.999)

    def failure(self, source):
        now = time.monotonic()
        st = self.sources.setdefault(source, [0, 0.0])
        st[0] += 1
        if st[0] >= self.PER_SOURCE:
            st[1] = now + min(self.MAX_LOCK, self.BASE_LOCK * 2 ** (st[0] - self.PER_SOURCE))
        self.recent = [t for t in self.recent if now - t < self.GLOBAL_WINDOW] + [now]
        if len(self.recent) >= self.GLOBAL_MAX:
            self.global_until = now + min(self.MAX_LOCK, 60 * 2 ** self.global_level)
            self.global_level += 1
            self.recent.clear()
        if len(self.sources) > 4096:  # bound memory under a flood of sources
            self.sources = {k: v for k, v in self.sources.items() if v[1] > now}

    def success(self, source):
        self.sources.pop(source, None)
