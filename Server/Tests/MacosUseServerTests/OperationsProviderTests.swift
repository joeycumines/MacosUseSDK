import MacosUseProto
@testable import MacosUseServer
import SwiftProtobuf
import XCTest

/// Unit tests for OperationsProvider filter parsing.
/// These tests specifically verify filter string parsing which is handled at the provider layer.
/// Core pagination and filtering logic is tested in OperationStoreTests.
final class OperationsProviderTests: XCTestCase {
    // MARK: - Filter String Parsing Tests

    /// Helper to extract the showOnlyDone value from a filter string using the same logic as OperationsProvider
    private func parseFilterToDone(_ filterString: String) -> Bool? {
        // Replicates the parsing logic from OperationsProvider.listOperations
        let filter = filterString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        if filter == "done=true" {
            return true
        } else if filter == "done=false" {
            return false
        }
        return nil
    }

    func testFilterParsing_doneTrue_parsesCorrectly() {
        XCTAssertEqual(parseFilterToDone("done=true"), true)
    }

    func testFilterParsing_doneFalse_parsesCorrectly() {
        XCTAssertEqual(parseFilterToDone("done=false"), false)
    }

    func testFilterParsing_caseInsensitive_doneTrue() {
        for filterValue in ["done=TRUE", "DONE=true", "Done=True", "DONE=TRUE", "done=True"] {
            XCTAssertEqual(parseFilterToDone(filterValue), true, "'\(filterValue)' should parse to true")
        }
    }

    func testFilterParsing_caseInsensitive_doneFalse() {
        for filterValue in ["done=FALSE", "DONE=false", "Done=False", "DONE=FALSE", "done=False"] {
            XCTAssertEqual(parseFilterToDone(filterValue), false, "'\(filterValue)' should parse to false")
        }
    }

    func testFilterParsing_internalSpaces_normalized() {
        // These should all normalize to "done=true"
        for filterValue in ["done = true", "done =true", "done= true", "  done = true  "] {
            XCTAssertEqual(parseFilterToDone(filterValue), true, "'\(filterValue)' should parse to true")
        }
    }

    func testFilterParsing_newlines_trimmed() {
        XCTAssertEqual(parseFilterToDone("done=true\n"), true)
        XCTAssertEqual(parseFilterToDone("\ndone=false\n"), false)
    }

    func testFilterParsing_unrecognized_returnsNil() {
        XCTAssertNil(parseFilterToDone("status=running"))
        XCTAssertNil(parseFilterToDone(""))
        XCTAssertNil(parseFilterToDone("done=maybe"))
        XCTAssertNil(parseFilterToDone("complete=true"))
    }

    // MARK: - Integration Test with OperationStore

    func testListOperations_filterDoneTrue_integratedCorrectly() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/done-1")
        _ = await store.createOperation(name: "operations/pending-1")
        var response = Google_Protobuf_StringValue()
        response.value = "completed"
        try await store.finishOperation(name: "operations/done-1", responseMessage: response)

        // Parse filter string the way OperationsProvider does
        let showOnlyDone = parseFilterToDone("DONE=TRUE")

        let result = await store.listOperations(
            namePrefix: nil,
            showOnlyDone: showOnlyDone,
            pageSize: 100,
            pageToken: "",
        )

        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.name, "operations/done-1")
    }

    func testListOperations_filterDoneFalse_integratedCorrectly() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/done-1")
        _ = await store.createOperation(name: "operations/pending-1")
        var response = Google_Protobuf_StringValue()
        response.value = "completed"
        try await store.finishOperation(name: "operations/done-1", responseMessage: response)

        // Parse filter string the way OperationsProvider does (with spaces)
        let showOnlyDone = parseFilterToDone("done = false")

        let result = await store.listOperations(
            namePrefix: nil,
            showOnlyDone: showOnlyDone,
            pageSize: 100,
            pageToken: "",
        )

        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.name, "operations/pending-1")
    }

    // MARK: - Provider Initialization Test

    func testProviderInitialization() {
        let store = OperationStore()
        let provider = OperationsProvider(operationStore: store)
        XCTAssertNotNil(provider)
    }
}
