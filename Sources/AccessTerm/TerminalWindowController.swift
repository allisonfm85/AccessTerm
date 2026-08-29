import AppKit

/// One terminal window: a window, its MainViewController, and the shell session the
/// controller owns. The app used to be one hard-wired window; File > New Window and
/// File > New Tab mean there can be several, so everything about one terminal's lifetime
/// lives here -- above all, ending its shell when its window goes away, and asking first
/// when something is still running in it.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {

    let mainController: MainViewController
    /// Called after the window has closed and the session is down, so the app delegate can
    /// let go of this controller.
    var onClose: ((TerminalWindowController) -> Void)?

    init() {
        mainController = MainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AccessTerm"
        window.contentViewController = mainController
        // The same identifier on every terminal window is what lets macOS gather them as
        // tabs of one another (File > New Tab, and the window manager's own merging).
        window.tabbingIdentifier = "AccessTermTerminal"
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Closing

    /// Command-W and the close button. A shell sitting at its prompt closes without a word;
    /// a window with a program still running -- a build, an editor, a Claude session -- asks
    /// first, because closing it kills that program with everything it holds. The alert is a
    /// standard one, which VoiceOver reads on its own terms: the message, then the buttons.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard mainController.session.isRunning,
              mainController.session.programIsRunning else { return true }

        let alert = NSAlert()
        alert.messageText = "A program is still running in this window."
        alert.informativeText =
            "Closing the window will end it. Anything it has not saved will be lost."
        alert.addButton(withTitle: "Close Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        mainController.session.terminate()
        onClose?(self)
    }
}
