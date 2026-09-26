// Darpan for Mac: a native client for the Darpan remote desktop (PROTOCOL.md).
import AppKit

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
