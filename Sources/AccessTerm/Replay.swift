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
        private var news = LineNews()
        /// Mirrors the UI's suppression of a live question that later arrives as a line.
        private var announcedLiveText = ""

        func session(_ session: TerminalSession, didUpdate update: TerminalUpdate) {
            guard update.alternateScreen == nil else { return }
            liveText = update.liveText
            let alreadySpoken = announcedLiveText
            var lines = news.news(in: update)
            if !alreadySpoken.isEmpty {
                lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == alreadySpoken }
            }
            announced.append(contentsOf: lines + liveQuestion(in: update))
        }

        /// The UI's rule, so a capture shows what it would actually say: a live line is a
        /// program's question only while a command is running.
        private func liveQuestion(in update: TerminalUpdate) -> [String] {
            guard update.programIsRunning else {
                announcedLiveText = ""
                return []
            }
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
