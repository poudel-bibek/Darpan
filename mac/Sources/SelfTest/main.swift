// Self-tests for DarpanCore (XCTest isn't part of the Command Line Tools).
// `swift run SelfTest` — exits non-zero if anything fails. build.sh runs it before packaging.
import Foundation

protocolTests()
videoTests()
inputTests()
audioTests()

print(failures == 0 ? "PASS: \(checks) checks" : "FAILED: \(failures) of \(checks) checks")
exit(failures == 0 ? 0 : 1)
