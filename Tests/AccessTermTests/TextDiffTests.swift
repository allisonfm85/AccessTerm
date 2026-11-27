import XCTest
@testable import AccessTerm

final class TextDiffTests: XCTestCase {
    private func apply(_ old: String, _ new: String) -> String? {
        guard let edit = TextDiff.minimalEdit(from: old, to: new) else { return nil }
        return (old as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testIdenticalIsNil() {
        XCTAssertNil(TextDiff.minimalEdit(from: "same\ntext\n", to: "same\ntext\n"))
    }

    func testChangeInTheMiddleTouchesOnlyThatRange() {
        let edit = TextDiff.minimalEdit(from: "one\ntwo\nthree\n", to: "one\nTWO!\nthree\n")
        XCTAssertEqual(edit?.range, NSRange(location: 4, length: 3))
        XCTAssertEqual(edit?.replacement, "TWO!")
    }

    func testAppendAndTruncate() {
        XCTAssertEqual(apply("abc", "abcdef"), "abcdef")
        XCTAssertEqual(apply("abcdef", "abc"), "abc")
        XCTAssertEqual(apply("", "x"), "x")
        XCTAssertEqual(apply("x", ""), "")
    }

    func testRepeatedCharactersDoNotOverlapPrefixAndSuffix() {
        XCTAssertEqual(apply("aaaa", "aaaaaa"), "aaaaaa")
        XCTAssertEqual(apply("aaaaaa", "aaaa"), "aaaa")
        XCTAssertEqual(apply("abab", "ab"), "ab")
    }

    func testSurrogatePairsAreNotSplit() {
        // 😀 and 😁 share their lead surrogate.
        XCTAssertEqual(apply("a😀b", "a😁b"), "a😁b")
        let edit = TextDiff.minimalEdit(from: "😀", to: "😁")
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 2))
    }

    func testAlwaysReproducesTheNewText() {
        let samples = ["", "a", "ab\ncd\n", "ab\nXd\n", "ééé", "日本語\n日本\n", "x😀y😁z"]
        for old in samples { for new in samples where old != new {
            XCTAssertEqual(apply(old, new), new, "\(old) -> \(new)")
        } }
    }
}
