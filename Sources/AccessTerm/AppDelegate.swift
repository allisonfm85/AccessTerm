import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminalControllers: [TerminalWindowController] = []
    /// Watches for Option-Command-W: see installCloseAllKeyMonitor.
    private var closeAllKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        installCloseAllKeyMonitor()
        openTerminalWindow(asTab: false)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Command-Q with a program still running somewhere asks first, the same way Command-W
    /// does for one window (see TerminalWindowController). Quitting kills every shell at
    /// once, so this is the same hazard with a bigger reach.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = terminalControllers.filter {
            $0.mainController.session.isRunning && $0.mainController.session.programIsRunning
        }
        guard !busy.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = busy.count == 1
            ? "A program is still running."
            : "Programs are still running in \(busy.count) windows."
        alert.informativeText =
            "Quitting AccessTerm will end them. Anything they have not saved will be lost."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in terminalControllers {
            controller.mainController.session.terminate()
        }
    }

    // MARK: - Windows

    /// Every terminal window comes from here. The first window remembers its own frame; the
    /// ones after it step down and right from the front window, the way new windows do
    /// everywhere on the Mac. As a tab, the new window joins the front terminal window's tab
    /// group instead and macOS places it.
    @discardableResult
    private func openTerminalWindow(asTab: Bool) -> TerminalWindowController {
        let controller = TerminalWindowController()
        controller.onClose = { [weak self] closed in
            self?.terminalControllers.removeAll { $0 === closed }
        }

        let front = frontTerminalWindow
        if asTab, let front, let window = controller.window {
            front.addTabbedWindow(window, ordered: .above)
        } else if terminalControllers.isEmpty {
            controller.window?.center()
            controller.window?.setFrameAutosaveName("AccessTermMainWindow")
        } else if let front, let window = controller.window {
            window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY))
        }

        terminalControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private var frontTerminalWindow: NSWindow? {
        if let key = NSApp.keyWindow,
           terminalControllers.contains(where: { $0.window === key }) {
            return key
        }
        return terminalControllers.last?.window
    }

    @objc func newWindow(_ sender: Any?) {
        openTerminalWindow(asTab: false)
    }

    @objc func newTab(_ sender: Any?) {
        openTerminalWindow(asTab: true)
    }

    /// The plus button on the tab bar, and the system's own "new tab" affordances, look for
    /// this selector in the responder chain.
    @objc func newWindowForTab(_ sender: Any?) {
        openTerminalWindow(asTab: true)
    }

    /// Option-Command-W. Each window is asked to close the ordinary way, which is what
    /// keeps the running-program confirmation in the loop: an idle window goes quietly, a
    /// busy one asks, and Cancel keeps that one window open while the sweep moves on. The
    /// list is copied up front because closing windows edits it out from under a live walk.
    @objc func closeAllTerminalWindows(_ sender: Any?) {
        for controller in Array(terminalControllers) {
            controller.window?.performClose(sender)
        }
    }

    /// Reads Option-Command-W off the keyboard, because the menu's key equivalent cannot be
    /// trusted to arrive: key equivalents are offered to the key window before the main
    /// menu, and when windows are tabbed, the tab machinery claims this chord and closes
    /// one tab -- clicking File > Close All always worked; pressing its shortcut with a tab
    /// group present did not. This is the block-step lesson over again (see
    /// MainViewController's key monitor): when the dispatch path misbehaves, take the chord
    /// at the door and swallow the event so nothing downstream can reinterpret it. The menu
    /// item stays, both for choosing it from the menu and for naming the shortcut.
    private func installCloseAllKeyMonitor() {
        closeAllKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  NSApp.modalWindow == nil,
                  event.charactersIgnoringModifiers?.lowercased() == "w",
                  event.modifierFlags.intersection([.command, .option, .control, .shift])
                      == [.command, .option] else { return event }
            self.closeAllTerminalWindows(nil)
            return nil
        }
    }

    // MARK: - Help

    @objc func openHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/allisonfm85/AccessTerm#readme") {
            NSWorkspace.shared.open(url)
        }
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
        let services = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AccessTerm",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AccessTerm",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window",
                         action: #selector(AppDelegate.newWindow(_:)),
                         keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(AppDelegate.newTab(_:)),
                         keyEquivalent: "t")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        // The system synthesizes a Close All alternate for a plain Close item, but with a
        // tab group it closed only one tab in practice. Supplying our own alternate replaces
        // the synthesized one with something whose behavior is ours to define: every
        // terminal window goes through performClose, so a window with a program running
        // still gets its confirmation, and Cancel there keeps that window without stopping
        // the rest from closing.
        let closeAll = fileMenu.addItem(withTitle: "Close All",
                                        action: #selector(AppDelegate.closeAllTerminalWindows(_:)),
                                        keyEquivalent: "w")
        closeAll.keyEquivalentModifierMask = [.command, .option]
        closeAll.isAlternate = true
        fileItem.submenu = fileMenu

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

        // Find gets a submenu of its own, the way every Mac text app has one. All four are
        // the same action dispatched by tag; the transcript's find bar answers them.
        let findItem = editMenu.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        let find = findMenu.addItem(withTitle: "Find\u{2026}",
                                    action: #selector(NSTextView.performTextFinderAction(_:)),
                                    keyEquivalent: "f")
        find.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        let findNext = findMenu.addItem(withTitle: "Find Next",
                                        action: #selector(NSTextView.performTextFinderAction(_:)),
                                        keyEquivalent: "g")
        findNext.tag = Int(NSTextFinder.Action.nextMatch.rawValue)
        let findPrevious = findMenu.addItem(withTitle: "Find Previous",
                                            action: #selector(NSTextView.performTextFinderAction(_:)),
                                            keyEquivalent: "g")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        findPrevious.tag = Int(NSTextFinder.Action.previousMatch.rawValue)
        let useSelection = findMenu.addItem(withTitle: "Use Selection for Find",
                                            action: #selector(NSTextView.performTextFinderAction(_:)),
                                            keyEquivalent: "e")
        useSelection.tag = Int(NSTextFinder.Action.setSearchString.rawValue)
        findItem.submenu = findMenu

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

        // Command blocks. These two carry no key equivalent on purpose: a menu command
        // invoked by its shortcut is spoken by name before it runs, and a step is meant to be
        // one utterance -- the command landed on, and nothing else. The chords are read
        // straight off the keyboard instead (see MainViewController's key monitor) and named
        // in the titles, the way Interrupt names the key it sends.
        termMenu.addItem(withTitle: "Previous Command (Option-Command-Up)",
                         action: #selector(MainViewController.previousCommand(_:)),
                         keyEquivalent: "")
        termMenu.addItem(withTitle: "Next Command (Option-Command-Down)",
                         action: #selector(MainViewController.nextCommand(_:)),
                         keyEquivalent: "")
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

        // Window menu. macOS adds its own tab commands (Show Next Tab, Move Tab to New
        // Window, Merge All Windows) here once tabbed windows exist, and lists the open
        // windows at the bottom because this is the windows menu.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Help menu. There is no help book; the README is the manual, so this opens it.
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "AccessTerm Help",
                         action: #selector(AppDelegate.openHelp(_:)),
                         keyEquivalent: "?")
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}
