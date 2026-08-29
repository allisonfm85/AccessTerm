import Foundation

/// Replays a raw pty log (see ACCESSTERM_LOG) through the transcript assembly and prints the
/// transcript it produces, without a window, a shell or a pty. It is how a capture of a
/// program that misbehaves becomes a repeatable check.
///
/// The bytes are fed in small chunks with the update timer running, so the assembly sees them
/// arriving the way they arrived from the pty rather than as one lump.
enum Replay {
    static func run(path: String) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            return 1
        }

        let session = TerminalSession()
        let sink = Sink()
        session.delegate = sink

        let bytes = [UInt8](data)
        let chunk = 512
        var offset = 0
        // The pty hands over what has arrived so far; feeding in chunks and letting the run
        // loop turn between them puts the coalescing timer under the same pressure it is
        // under live.
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            session.dataReceived(slice: bytes[offset..<end])
            offset = end
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        session.publishUpdate()

        // SwiftTerm logs the odd unhandled sequence to stdout while parsing, so mark where
        // the transcript starts.
        print("--- transcript ---")
        for line in session.transcript.lines { print(line) }
        print("--- announced ---")
        for line in sink.announced { print(line) }
        // Machine-checkable proof of what got colored, without needing eyes. Off unless
        // asked, so the default output -- what the regression diffs -- is unchanged.
        if ProcessInfo.processInfo.environment["ACCESSTERM_STYLE_DEBUG"] != nil {
            print("--- styles ---")
            for line in sink.styles { print(line) }
        }
        print("--- blocks ---")
        for block in session.commandBlocks where !block.command.isEmpty {
            print("block \(block.commandLine): \(block.command) "
                  + "output \(block.outputLines.lowerBound)..<\(block.outputLines.upperBound)"
                  + (block.isFinished ? " finished" : " running")
                  + (block.exitCode.map { " exit \($0)" } ?? ""))
            for turn in block.turns {
                print("  turn \(turn.commandLine): \(turn.command) "
                      + "output \(turn.outputLines.lowerBound)..<\(turn.outputLines.upperBound)"
                      + (turn.isFinished ? " finished" : " running"))
            }
        }
        FileHandle.standardError.write(Data("--- live: \(sink.liveText)\n".utf8))
        return 0
    }

    /// Takes the updates and does nothing with them: the transcript itself is what is being
    /// checked, and the session holds that.
    private final class Sink: TerminalSessionDelegate {
        var liveText = ""
        /// Everything that would have been spoken, in order, so a capture can be checked for
        /// what it would sound like as well as for what it would read like.
        var announced: [String] = []
        /// One entry per styled line seen, for the --- styles --- section. Records edits and
        /// appends alike, in arrival order, so recolored lines show their latest coat.
        var styles: [String] = []
        private var news = LineNews()
        /// Mirrors the UI's suppression of a live question that later arrives as a line.
        private var announcedLiveText = ""

        private func recordStyles(line: Int, runs: [StyleRun]) {
            guard !runs.isEmpty else { return }
            let described = runs.map { run -> String in
                var parts: [String] = []
                if let color = run.color { parts.append("fg \(describe(color))") }
                if let background = run.background { parts.append("bg \(describe(background))") }
                if run.bold { parts.append("bold") }
                if run.underline { parts.append("underline") }
                return "[\(run.range.location)..\(NSMaxRange(run.range))] " + parts.joined(separator: " ")
            }
            styles.append("line \(line): " + described.joined(separator: ", "))
        }

        private func describe(_ color: TerminalColor) -> String {
            switch color {
            case .ansi(let code): return "ansi\(code)"
            case .rgb(let red, let green, let blue): return "rgb(\(red),\(green),\(blue))"
            }
        }

        func session(_ session: TerminalSession, didCompleteLine buffer: String, cursor: Int) {
            announced.append("completion: \(buffer) (cursor \(cursor))")
        }

        func session(_ session: TerminalSession, didUpdate update: TerminalUpdate) {
            guard update.alternateScreen == nil else { return }
            for (index, runs) in update.editStyles.enumerated() where index < update.edits.count {
                recordStyles(line: update.edits[index].line, runs: runs)
            }
            for (index, runs) in update.newLineStyles.enumerated() {
                recordStyles(line: update.firstNewLine + index, runs: runs)
            }
            liveText = update.liveText
            let alreadySpoken = announcedLiveText
            var lines = news.news(in: update)
            if !alreadySpoken.isEmpty {
                lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == alreadySpoken }
            }
            announced.append(contentsOf: (lines + liveQuestion(in: update)).map(PromptDefault.spoken))
        }

        /// The UI's rule, so a capture shows what it would actually say: a live line is a
        /// program's question only while a command is running.
        private func liveQuestion(in update: TerminalUpdate) -> [String] {
            guard update.programIsRunning else {
                announcedLiveText = ""
                return []
            }
            // A command that has printed nothing yet leaves the line it was typed on as the
            // nearest thing on screen. It is shown, but it is the user's own typing coming back.
            guard !update.liveTextIsUserEcho else { return [] }
            let question = update.liveText.trimmingCharacters(in: .whitespaces)
            guard !question.isEmpty, question != announcedLiveText else { return [] }
            announcedLiveText = question
            return [question]
        }
        func sessionDidRingBell(_ session: TerminalSession) {}
        func session(_ session: TerminalSession, didChangeTitle title: String) {}
        func session(_ session: TerminalSession, didTerminateWithExitCode code: Int32?) {}
    }
}
