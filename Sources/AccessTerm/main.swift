import AppKit

// Diagnostic: --replay <raw log> runs a capture through the transcript assembly and prints
// the result, instead of opening a window. See "Diagnostics" in the README.
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--replay"), index + 1 < arguments.count {
    exit(Replay.run(path: arguments[index + 1]))
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
