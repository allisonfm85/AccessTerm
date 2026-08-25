import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var mainController: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        mainController = MainViewController()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AccessTerm"
        window.contentViewController = mainController
        window.center()
        window.setFrameAutosaveName("AccessTermMainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainController?.session.terminate()
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About AccessTerm",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AccessTerm",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AccessTerm",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit menu (standard selectors travel the responder chain)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // The transcript text view has a find bar, but Command-F only reaches it through a
        // main menu key equivalent, and the action is dispatched by tag.
        let find = editMenu.addItem(withTitle: "Find\u{2026}",
                                    action: #selector(NSTextView.performTextFinderAction(_:)),
                                    keyEquivalent: "f")
        find.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        editMenu.addItem(.separator())
        let copyAll = editMenu.addItem(withTitle: "Copy Entire Transcript",
                                       action: #selector(MainViewController.copyAll(_:)),
                                       keyEquivalent: "c")
        copyAll.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = editMenu

        // Terminal menu
        let termItem = NSMenuItem()
        mainMenu.addItem(termItem)
        let termMenu = NSMenu(title: "Terminal")

        termMenu.addItem(withTitle: "Focus Transcript",
                         action: #selector(MainViewController.focusTranscript(_:)),
                         keyEquivalent: "1")
        termMenu.addItem(withTitle: "Focus Command Line",
                         action: #selector(MainViewController.focusCommandLine(_:)),
                         keyEquivalent: "2")
        let toEnd = termMenu.addItem(withTitle: "Go to End of Transcript",
                                     action: #selector(MainViewController.goToEnd(_:)),
                                     keyEquivalent: "e")
        toEnd.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(.separator())

        // Command blocks. Arrow keys as key equivalents are the function-key code points.
        let previous = termMenu.addItem(withTitle: "Previous Command",
                                        action: #selector(MainViewController.previousCommand(_:)),
                                        keyEquivalent: "\u{F700}")
        previous.keyEquivalentModifierMask = [.command, .option]
        let next = termMenu.addItem(withTitle: "Next Command",
                                    action: #selector(MainViewController.nextCommand(_:)),
                                    keyEquivalent: "\u{F701}")
        next.keyEquivalentModifierMask = [.command, .option]
        let copyOutput = termMenu.addItem(withTitle: "Copy Output of This Command",
                                          action: #selector(MainViewController.copyBlockOutput(_:)),
                                          keyEquivalent: "o")
        copyOutput.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(.separator())

        let readLine = termMenu.addItem(withTitle: "Read Current Line",
                                        action: #selector(MainViewController.readCurrentLine(_:)),
                                        keyEquivalent: "l")
        readLine.keyEquivalentModifierMask = [.command, .shift]
        let speak = termMenu.addItem(withTitle: "Speak Output",
                                     action: #selector(MainViewController.toggleSpeakOutput(_:)),
                                     keyEquivalent: "s")
        speak.keyEquivalentModifierMask = [.command, .shift]
        termMenu.addItem(.separator())

        termMenu.addItem(withTitle: "Interrupt (Control-C)",
                         action: #selector(MainViewController.interrupt(_:)),
                         keyEquivalent: ".")
        termMenu.addItem(withTitle: "Send Escape",
                         action: #selector(MainViewController.sendEscape(_:)),
                         keyEquivalent: "")
        termMenu.addItem(withTitle: "Send Shift-Tab (Claude Code: cycle mode)",
                         action: #selector(MainViewController.sendShiftTab(_:)),
                         keyEquivalent: "")
        termItem.submenu = termMenu

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
