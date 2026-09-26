// Self-tests for DarpanCore (XCTest isn't part of the Command Line Tools).
// `swift run SelfTest` — exits non-zero if anything fails. build.sh runs it before packaging.
import Foundation

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("  FAIL \(what())  (\(file):\(line))")
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ what: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
    check(a == b, "\(what()): got \(a), want \(b)", file: file, line: line)
}

func section(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  FAIL threw \(error)")
    }
}

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
