import Foundation
import DarpanCore

func protocolTests() {
    section("auth: PBKDF2 + HMAC known-answer vector (MAC_PROMPT §3)") {
        let salt = Data(base64Encoded: "c2FsdHNhbHRzYWx0c2FsdA==")!
        let nonce = Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")!
        let key = try Auth.deriveKey(password: "correct horse battery", salt: salt, iterations: 200_000)
        eq(hex(key), "a58c2cefe9e01e0464dad113872d0867db9889f547e517fb39ce046b3506a845", "key")
        eq(Auth.proof(key: key, nonce: nonce).base64EncodedString(), "AG+vUe6kdYyGhR8kh0ntx1CxNRsbCrdjnHuzYug1Sgg=", "proof")

        // NFC: "é" typed as e + combining acute must derive the same key as the precomposed form.
        let a = try Auth.deriveKey(password: "caf\u{E9}", salt: salt, iterations: 100_000)
        let b = try Auth.deriveKey(password: "cafe\u{301}", salt: salt, iterations: 100_000)
        eq(a, b, "NFC normalisation")

        // A host asking for a cheap KDF (or absurd parameters) is refused.
        check((try? Auth.deriveKey(password: "x", salt: salt, iterations: 1000)) == nil, "low iteration count refused")
        check((try? Auth.deriveKey(password: "x", salt: Data(), iterations: 200_000)) == nil, "empty salt refused")
        check((try? Auth.deriveKey(password: "", salt: salt, iterations: 100_000)) != nil, "empty password derives")

        let name = Auth.clientName()
        check(name.hasPrefix("Darpan for Mac 1.0.0 on macOS "), "client name: \(name)")
    }

    section("messages are valid JSON") {
        let texts: [String?] = [Msg.mm(1, 2), Msg.mb(0, true), Msg.mb(2, false, x: 3, y: 4), Msg.wh(dx: -1, dy: 240),
                                Msg.key("KeyA", true), Msg.ack(stream: 65535, seq: 4_294_967_295), Msg.ping(12345.678),
                                Msg.start(fps: 60, bitrate: 0), Msg.cfg(fps: 30), Msg.cfg(bitrate: 8000), Msg.cfg(fps: 60, bitrate: 0),
                                Msg.res(w: 1920, h: 1080), Msg.resNative, Msg.modes, Msg.rel, Msg.kf, Msg.stop,
                                Msg.auth(proof: Data([1, 2, 3]), client: "Darpan \"test\""), Msg.txt("héllo ✓\n\"x\""),
                                Msg.clip("a/b\\c"), Msg.fput(id: 1, name: "ré port.pdf", size: 123), Msg.fabort(id: 9)]
        for (i, t) in texts.enumerated() {
            guard let t, let m = Incoming(Data(t.utf8)) else { check(false, "message \(i) parses"); continue }
            check(!m.type.isEmpty, "type in \(t)")
        }
        let mb = Incoming(Data(Msg.mb(2, false, x: 3, y: 4).utf8))!
        eq(mb.int("b"), 2, "mb.b")
        eq(mb.bool("d"), false, "mb.d")
        eq(Incoming(Data(Msg.ping(12345.678).utf8))!.double("c"), 12345.678, "ping.c")
        let huge = Incoming(Data(#"{"t":"stream","id":9223372036854775807,"w":1e300,"h":-9223372036854775809}"#.utf8))!
        check(huge.int("id") == nil && huge.int("w") == nil && huge.int("h") == Int.min, "out-of-range numbers are nil, not a trap")
        eq(Incoming(Data(Msg.txt("héllo ✓\n\"x\"")!.utf8))!.string("s"), "héllo ✓\n\"x\"", "txt round trip")
        eq(Incoming(Data(Msg.cfg(fps: 60, bitrate: 0).utf8))!.int("bitrate"), 0, "cfg.bitrate")
        let modes = Incoming(Data(#"{"t":"modes","current":[2560,1440],"modes":[[2560,1440],[1920,1080],["x",1]],"changed":false}"#.utf8))!
        eq(modes.mode("current"), DisplayMode(2560, 1440), "modes.current")
        eq(modes.modes("modes"), [DisplayMode(2560, 1440), DisplayMode(1920, 1080)], "malformed entries ignored")
        eq(modes.bool("changed"), false, "bool")
        eq(modes.int("changed"), nil, "a bool is not a number")
        check(Incoming(Data("[1,2]".utf8)) == nil, "non-object ignored")
        check(Incoming(Data(#"{"x":1}"#.utf8)) == nil, "no type ignored")
        eq(hex(FileChunk.message(id: 0x0A0B_0C0D, data: Data([0xFF]))), "020a0b0c0dff", "FILE_CHUNK framing")
    }

    section("host addresses") {
        func parse(_ s: String) -> HostAddress? { try? HostAddress(parsing: s) }
        let a = parse("  workstation.example.ts.net  ")
        eq(a?.origin, "https://workstation.example.ts.net", "scheme added")
        eq(a?.webSocketURL.absoluteString, "wss://workstation.example.ts.net/ws", "wss /ws")
        eq(a?.shortName, "workstation", "short name")
        eq(parse("https://Host.TS.net/")?.origin, "https://host.ts.net", "lowercased, path dropped")
        eq(parse("https://host.ts.net:443/ws")?.webSocketURL.absoluteString, "wss://host.ts.net/ws", "default port dropped")
        eq(parse("wss://host.ts.net:8443")?.webSocketURL.absoluteString, "wss://host.ts.net:8443/ws", "custom port kept")
        eq(parse("http://127.0.0.1:47470")?.webSocketURL.absoluteString, "ws://127.0.0.1:47470/ws", "plain ws to loopback")
        eq(parse("ws://localhost:47470/ws")?.origin, "http://localhost:47470", "localhost")
        eq(parse("http://[::1]:47470")?.webSocketURL.absoluteString, "ws://[::1]:47470/ws", "IPv6 loopback")
        func problem(_ s: String) -> HostAddress.Problem? {
            do { _ = try HostAddress(parsing: s); return nil } catch { return error as? HostAddress.Problem }
        }
        eq(problem("http://host.ts.net"), .insecure, "plain http to a remote host refused")
        eq(problem("ws://192.0.2.10:47470"), .insecure, "plain ws to a tailnet IP refused")
        eq(problem("http://127.0.0.1.evil.com"), .insecure, "loopback look-alike refused")
        eq(problem("https://user:pw@example.com"), .credentials, "credentials refused")
        eq(problem(""), .empty, "empty")
        eq(problem("ftp://host"), .invalid, "other schemes")
        eq(problem("https://"), .invalid, "no host")
    }

    section("clock sync and latency") {
        var c = ClockSync()
        // Host clock = local + 5 s. Ping sent at 1000 ms, pong at 1020 ms: the host stamped it mid-way.
        c.pong(c: 1000, s: (1010 + 5000) * 1000, now: 1020)
        eq(c.rtt, 20, "rtt")
        eq(c.offsetUs, 5_000_000, "offset")
        // A frame captured at host 6000 ms (= local 1000 ms), displayed at local 1030 ms → 30 ms.
        eq(c.latency(captureUs: 6_000_000, now: 1030), 30, "capture → display")
        c.pong(c: 2000, s: (2040 + 5000) * 1000, now: 2080)       // slower sample: RTT smoothed, offset kept
        eq(c.rtt, 20 * 0.7 + 80 * 0.3, "EWMA")
        eq(c.offsetUs, 5_000_000, "offset from the tightest sample")
        c.pong(c: 40000, s: (40005 + 5000) * 1000 + 700, now: 40010)  // after 30 s the newest sample wins
        eq(c.offsetUs, 5_000_700, "offset refreshed")
        check(ClockSync().latency(captureUs: 1, now: 1) == nil, "no offset yet")
    }
}
