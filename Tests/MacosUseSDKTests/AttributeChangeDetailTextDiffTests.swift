@testable import MacosUseSDK
import XCTest

/// Unit tests for AttributeChangeDetail text diff initializer.
///
/// The `init(textBefore:textAfter:)` initializer uses Swift's CollectionDifference
/// to compute character-level additions and removals between two strings.
final class AttributeChangeDetailTextDiffTests: XCTestCase {
    // MARK: - Basic Text Changes

    func testTextDiff_appendingText() {
        // "" → "hello" should show all characters as added
        let detail = AttributeChangeDetail(textBefore: "", textAfter: "hello")

        XCTAssertEqual(detail.attributeName, "text")
        XCTAssertEqual(detail.addedText, "hello")
        XCTAssertNil(detail.removedText)
    }

    func testTextDiff_removingAllText() {
        // "hello" → "" should show all characters as removed
        let detail = AttributeChangeDetail(textBefore: "hello", textAfter: "")

        XCTAssertNil(detail.addedText)
        // CollectionDifference may order removals differently; check characters
        XCTAssertEqual(Set(detail.removedText ?? ""), Set("hello"))
        XCTAssertEqual(detail.removedText?.count, 5)
    }

    func testTextDiff_insertInMiddle() {
        // "hllo" → "hello" should detect 'e' insertion
        let detail = AttributeChangeDetail(textBefore: "hllo", textAfter: "hello")

        XCTAssertEqual(detail.addedText, "e")
        XCTAssertNil(detail.removedText)
    }

    func testTextDiff_removeFromMiddle() {
        // "hello" → "hllo" should detect 'e' removal
        let detail = AttributeChangeDetail(textBefore: "hello", textAfter: "hllo")

        XCTAssertNil(detail.addedText)
        XCTAssertEqual(detail.removedText, "e")
    }

    func testTextDiff_replaceCharacter() {
        // "hello" → "jello" should show 'h' removed and 'j' added
        let detail = AttributeChangeDetail(textBefore: "hello", textAfter: "jello")

        XCTAssertEqual(detail.addedText, "j")
        XCTAssertEqual(detail.removedText, "h")
    }

    func testTextDiff_noChange() {
        // "same" → "same" should have no additions or removals
        let detail = AttributeChangeDetail(textBefore: "same", textAfter: "same")

        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testTextDiff_emptyToEmpty() {
        // "" → "" should have no additions or removals
        let detail = AttributeChangeDetail(textBefore: "", textAfter: "")

        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    // MARK: - Nil Handling

    func testTextDiff_nilToText() {
        // nil → "hello" should show all text as added
        let detail = AttributeChangeDetail(textBefore: nil, textAfter: "hello")

        XCTAssertEqual(detail.addedText, "hello")
        XCTAssertNil(detail.removedText)
    }

    func testTextDiff_textToNil() {
        // "hello" → nil should show all text as removed
        let detail = AttributeChangeDetail(textBefore: "hello", textAfter: nil)

        XCTAssertNil(detail.addedText)
        // CollectionDifference may order removals differently; check characters
        XCTAssertEqual(Set(detail.removedText ?? ""), Set("hello"))
        XCTAssertEqual(detail.removedText?.count, 5)
    }

    func testTextDiff_nilToNil() {
        // nil → nil should have no changes
        let detail = AttributeChangeDetail(textBefore: nil, textAfter: nil)

        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    // MARK: - Old/New Values Are Nil for Text

    func testTextDiff_oldNewValuesAreNil() {
        // For text changes, oldValue and newValue should be nil (diff provides the info instead)
        let detail = AttributeChangeDetail(textBefore: "old", textAfter: "new")

        XCTAssertNil(detail.oldValue)
        XCTAssertNil(detail.newValue)
    }

    // MARK: - Complex Changes

    func testTextDiff_multipleInsertions() {
        // "ac" → "abc" should detect 'b' insertion
        let detail = AttributeChangeDetail(textBefore: "ac", textAfter: "abc")

        XCTAssertEqual(detail.addedText, "b")
        XCTAssertNil(detail.removedText)
    }

    func testTextDiff_multipleDeletions() {
        // "hello" → "hlo" should detect 'e' and 'l' removed
        let detail = AttributeChangeDetail(textBefore: "hello", textAfter: "hlo")

        XCTAssertNil(detail.addedText)
        // CollectionDifference removes 'e' and one 'l'
        XCTAssertEqual(detail.removedText?.count, 2)
        XCTAssertTrue(detail.removedText?.contains("e") == true)
        XCTAssertTrue(detail.removedText?.contains("l") == true)
    }

    func testTextDiff_completeReplacement() {
        // "abc" → "xyz" should show all of abc removed and xyz added
        let detail = AttributeChangeDetail(textBefore: "abc", textAfter: "xyz")

        // Order may vary due to CollectionDifference processing; verify characters present
        XCTAssertEqual(Set(detail.addedText ?? ""), Set("xyz"))
        XCTAssertEqual(Set(detail.removedText ?? ""), Set("abc"))
    }

    // MARK: - Unicode Support

    func testTextDiff_emojiInsertion() {
        // "Hi" → "Hi👋" should detect emoji added
        let detail = AttributeChangeDetail(textBefore: "Hi", textAfter: "Hi👋")

        XCTAssertEqual(detail.addedText, "👋")
        XCTAssertNil(detail.removedText)
    }

    func testTextDiff_emojiRemoval() {
        // "Hello👋" → "Hello" should detect emoji removed
        let detail = AttributeChangeDetail(textBefore: "Hello👋", textAfter: "Hello")

        XCTAssertNil(detail.addedText)
        XCTAssertEqual(detail.removedText, "👋")
    }

    func testTextDiff_japaneseText() {
        // "こんにちは" → "こんにちは世界" should detect "世界" added
        let detail = AttributeChangeDetail(textBefore: "こんにちは", textAfter: "こんにちは世界")

        XCTAssertEqual(detail.addedText, "世界")
        XCTAssertNil(detail.removedText)
    }

    // MARK: - Edge Cases

    func testTextDiff_singleCharacterAdd() {
        // "a" → "ab" should detect 'b' added
        let detail = AttributeChangeDetail(textBefore: "a", textAfter: "ab")

        XCTAssertEqual(detail.addedText, "b")
        XCTAssertNil(detail.removedText)
    }

    func testTextDiff_singleCharacterRemove() {
        // "ab" → "a" should detect 'b' removed
        let detail = AttributeChangeDetail(textBefore: "ab", textAfter: "a")

        XCTAssertNil(detail.addedText)
        XCTAssertEqual(detail.removedText, "b")
    }

    func testTextDiff_whitespaceChanges() {
        // "hello world" → "helloworld" should detect space removed
        let detail = AttributeChangeDetail(textBefore: "hello world", textAfter: "helloworld")

        XCTAssertNil(detail.addedText)
        XCTAssertEqual(detail.removedText, " ")
    }

    func testTextDiff_newlineChanges() {
        // "line1\nline2" → "line1line2" should detect newline removed
        let detail = AttributeChangeDetail(textBefore: "line1\nline2", textAfter: "line1line2")

        XCTAssertNil(detail.addedText)
        XCTAssertEqual(detail.removedText, "\n")
    }
}
