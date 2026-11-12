import AppKit

/// The tone that stands for an indentation: a short sine blip, higher for deeper. Built in
/// memory as a WAV and played with NSSound, so there is no audio engine to run and nothing
/// to ship. VoiceOver plays its own for the text it reads itself; this is the one for lines
/// AccessTerm announces.
enum ToneSpeaker {
    static let sampleRate = 44_100
    static let duration = 0.06

    /// 220 Hz, rising three semitones for each four columns, up to 32 columns.
    static func frequency(forIndent indent: Int) -> Double {
        220 * pow(2, Double(max(0, min(indent, 32))) / 16)
    }

    /// 16-bit mono PCM in a WAV container, with a short fade at each end so it does not click.
    static func wav(forIndent indent: Int) -> Data {
        let frames = Int(Double(sampleRate) * duration)
        let fade = max(1, sampleRate / 200)
        let hertz = frequency(forIndent: indent)
        var samples = [Int16]()
        samples.reserveCapacity(frames)
        for n in 0..<frames {
            let envelope = min(1, Double(n) / Double(fade), Double(frames - 1 - n) / Double(fade))
            let value = sin(2 * Double.pi * hertz * Double(n) / Double(sampleRate)) * 0.25 * envelope
            samples.append(Int16(value * Double(Int16.max)))
        }
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append32(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append32(16)
        append16(1); append16(1); append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(byteCount)
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        return data
    }

    private static var cache: [Int: Data] = [:]
    private static var playing: [NSSound] = []

    static func play(indent: Int) {
        let key = max(0, min(indent, 32))
        let data = cache[key] ?? wav(forIndent: key)
        cache[key] = data
        guard let sound = NSSound(data: data) else { return }
        playing.removeAll { !$0.isPlaying }
        playing.append(sound)
        sound.play()
    }
}
