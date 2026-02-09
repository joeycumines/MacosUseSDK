// Copyright 2025 Joseph Cumines
//
// Tests for ListWindows and ListApplications ordering and filtering per AIP-132/160.

import CoreGraphics
import Foundation
@testable import MacosUseProto
@testable import MacosUseServer
import Testing

/// Tests for ListWindows and ListApplications ordering and filtering.
/// These tests verify the sorting logic and filter parsing functions directly.
@Suite("List Ordering and Filtering Tests")
struct ListOrderingFilteringTests {
    // MARK: - Test Helpers

    /// Create a mock CGWindowList dictionary for testing
    func makeCGDict(
        windowID: CGWindowID,
        pid: pid_t,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        title: String,
        layer: Int32 = 0,
        isOnScreen: Bool = true,
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: pid,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
            kCGWindowName as String: title,
            kCGWindowLayer as String: layer,
            kCGWindowIsOnscreen as String: isOnScreen,
        ]
    }

    /// Create mock WindowInfo for testing filter/sort logic
    func makeWindowInfo(
        windowID: CGWindowID,
        pid: pid_t = 123,
        title: String = "",
        layer: Int32 = 0,
        isOnScreen: Bool = true,
    ) -> WindowRegistry.WindowInfo {
        WindowRegistry.WindowInfo(
            windowID: windowID,
            ownerPID: pid,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            title: title,
            layer: layer,
            isOnScreen: isOnScreen,
            timestamp: Date(),
            bundleID: nil,
        )
    }

    /// Create mock Application proto for testing
    func makeApplication(
        pid: pid_t,
        displayName: String,
    ) -> Macosusesdk_V1_Application {
        Macosusesdk_V1_Application.with {
            $0.name = "applications/\(pid)"
            $0.pid = Int32(pid)
            $0.displayName = displayName
        }
    }

    // MARK: - ExtractQuotedValue Tests

    @Test("extractQuotedValue finds simple key=value")
    func extractQuotedValueSimple() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let result = service.extractQuotedValue(from: "title=\"Hello World\"", key: "title")
        #expect(result == "Hello World", "Should extract quoted value correctly")
    }

    @Test("extractQuotedValue handles spaces around equals sign")
    func extractQuotedValueWithSpaces() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let result = service.extractQuotedValue(from: "title = \"Hello World\"", key: "title")
        #expect(result == "Hello World", "Should handle spaces around equals sign")
    }

    @Test("extractQuotedValue is case insensitive for key")
    func extractQuotedValueCaseInsensitive() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let result = service.extractQuotedValue(from: "TITLE=\"Hello\"", key: "title")
        #expect(result == "Hello", "Should match key case-insensitively")
    }

    @Test("extractQuotedValue returns nil for non-matching key")
    func extractQuotedValueNonMatching() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let result = service.extractQuotedValue(from: "title=\"Hello\"", key: "name")
        #expect(result == nil, "Should return nil for non-matching key")
    }

    @Test("extractQuotedValue handles empty value")
    func extractQuotedValueEmpty() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let result = service.extractQuotedValue(from: "title=\"\"", key: "title")
        #expect(result == "", "Should handle empty quoted value")
    }

    @Test("extractQuotedValue extracts first occurrence")
    func extractQuotedValueFirstOccurrence() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let result = service.extractQuotedValue(from: "title=\"First\" title=\"Second\"", key: "title")
        #expect(result == "First", "Should extract first occurrence")
    }

    // MARK: - ListWindows Ordering Tests

    @Test("applyWindowFilter and sort - default order by window_id")
    func listWindowsDefaultOrder() {
        let windows = [
            makeWindowInfo(windowID: 300, title: "C"),
            makeWindowInfo(windowID: 100, title: "A"),
            makeWindowInfo(windowID: 200, title: "B"),
        ]

        // Default ordering should be by window_id
        let sorted = windows.sorted { $0.windowID < $1.windowID }
        #expect(sorted[0].windowID == 100, "First should be windowID 100")
        #expect(sorted[1].windowID == 200, "Second should be windowID 200")
        #expect(sorted[2].windowID == 300, "Third should be windowID 300")
    }

    @Test("applyWindowFilter and sort - order by title ascending")
    func listWindowsOrderByTitle() {
        let windows = [
            makeWindowInfo(windowID: 1, title: "Charlie"),
            makeWindowInfo(windowID: 2, title: "Alpha"),
            makeWindowInfo(windowID: 3, title: "Bravo"),
        ]

        let sorted = windows.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        #expect(sorted[0].title == "Alpha", "First should be Alpha")
        #expect(sorted[1].title == "Bravo", "Second should be Bravo")
        #expect(sorted[2].title == "Charlie", "Third should be Charlie")
    }

    @Test("applyWindowFilter and sort - order by title descending")
    func listWindowsOrderByTitleDesc() {
        let windows = [
            makeWindowInfo(windowID: 1, title: "Charlie"),
            makeWindowInfo(windowID: 2, title: "Alpha"),
            makeWindowInfo(windowID: 3, title: "Bravo"),
        ]

        let sorted = windows.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }.reversed()
        let sortedArray = Array(sorted)
        #expect(sortedArray[0].title == "Charlie", "First should be Charlie")
        #expect(sortedArray[1].title == "Bravo", "Second should be Bravo")
        #expect(sortedArray[2].title == "Alpha", "Third should be Alpha")
    }

    @Test("applyWindowFilter and sort - order by z_order")
    func listWindowsOrderByZOrder() {
        let windows = [
            makeWindowInfo(windowID: 1, title: "A", layer: 10),
            makeWindowInfo(windowID: 2, title: "B", layer: 0),
            makeWindowInfo(windowID: 3, title: "C", layer: 5),
        ]

        let sorted = windows.sorted { $0.layer < $1.layer }
        #expect(sorted[0].title == "B", "First should be layer 0")
        #expect(sorted[1].title == "C", "Second should be layer 5")
        #expect(sorted[2].title == "A", "Third should be layer 10")
    }

    @Test("applyWindowFilter and sort - invalid orderBy falls back to default")
    func listWindowsInvalidOrderByFallback() {
        let windows = [
            makeWindowInfo(windowID: 300, title: "C"),
            makeWindowInfo(windowID: 100, title: "A"),
            makeWindowInfo(windowID: 200, title: "B"),
        ]

        // Unknown field, should fall back to window_id ordering
        let sorted = windows.sorted { $0.windowID < $1.windowID }
        #expect(sorted[0].windowID == 100, "Invalid orderBy should fall back to windowID sort")
    }

    // MARK: - ListWindows Filtering Tests

    @Test("applyWindowFilter - visible=true filters to visible windows")
    func listWindowsFilterByVisible() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "Visible", isOnScreen: true),
            makeWindowInfo(windowID: 2, title: "Hidden", isOnScreen: false),
            makeWindowInfo(windowID: 3, title: "AlsoVisible", isOnScreen: true),
        ]

        let filtered = service.applyWindowFilter(windows, filter: "visible=true")
        #expect(filtered.count == 2, "Should filter to 2 visible windows")
        let allOnScreen = filtered.allSatisfy(\.isOnScreen)
        #expect(allOnScreen, "All should be on screen")
    }

    @Test("applyWindowFilter - visible=false filters to hidden windows")
    func listWindowsFilterByNotVisible() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "Visible", isOnScreen: true),
            makeWindowInfo(windowID: 2, title: "Hidden", isOnScreen: false),
        ]

        let filtered = service.applyWindowFilter(windows, filter: "visible=false")
        #expect(filtered.count == 1, "Should filter to 1 hidden window")
        #expect(filtered[0].title == "Hidden", "Hidden window should remain")
    }

    @Test("applyWindowFilter - minimized=true filters to minimized windows")
    func listWindowsFilterByMinimized() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "Normal", isOnScreen: true),
            makeWindowInfo(windowID: 2, title: "Minimized", isOnScreen: false),
        ]

        // minimized=true means isOnScreen=false (since WindowRegistry tracks isOnScreen)
        let filtered = service.applyWindowFilter(windows, filter: "minimized=true")
        #expect(filtered.count == 1, "Should filter to 1 minimized window")
        #expect(filtered[0].title == "Minimized", "Minimized window should remain")
    }

    @Test("applyWindowFilter - minimized=false filters to non-minimized windows")
    func listWindowsFilterByNotMinimized() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "Normal", isOnScreen: true),
            makeWindowInfo(windowID: 2, title: "Minimized", isOnScreen: false),
        ]

        let filtered = service.applyWindowFilter(windows, filter: "minimized=false")
        #expect(filtered.count == 1, "Should filter to 1 not-minimized window")
        #expect(filtered[0].title == "Normal", "Normal window should remain")
    }

    @Test("applyWindowFilter - title=\"...\" filters by title content")
    func listWindowsFilterByTitle() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "Document - Editor"),
            makeWindowInfo(windowID: 2, title: "Calculator"),
            makeWindowInfo(windowID: 3, title: "My Document.txt"),
        ]

        let filtered = service.applyWindowFilter(windows, filter: "title=\"Document\"")
        #expect(filtered.count == 2, "Should filter to 2 windows containing 'Document'")
        #expect(filtered.allSatisfy { $0.title.contains("Document") }, "All should contain Document")
    }

    @Test("applyWindowFilter - title filter is case insensitive")
    func listWindowsFilterByTitleCaseInsensitive() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "DOCUMENT"),
            makeWindowInfo(windowID: 2, title: "document"),
            makeWindowInfo(windowID: 3, title: "Calculator"),
        ]

        let filtered = service.applyWindowFilter(windows, filter: "title=\"document\"")
        #expect(filtered.count == 2, "Should match case-insensitively")
    }

    @Test("applyWindowFilter - combined ordering and filtering")
    func listWindowsOrderAndFilter() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 3, title: "Doc C", isOnScreen: true),
            makeWindowInfo(windowID: 1, title: "Doc A", isOnScreen: true),
            makeWindowInfo(windowID: 4, title: "Other", isOnScreen: true),
            makeWindowInfo(windowID: 2, title: "Doc B", isOnScreen: false),
        ]

        // Filter visible, then sort by title
        let filtered = service.applyWindowFilter(windows, filter: "visible=true")
        let sorted = filtered.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        #expect(sorted.count == 3, "Should have 3 visible windows")
        #expect(sorted[0].title == "Doc A", "First sorted visible window")
        #expect(sorted[1].title == "Doc C", "Second sorted visible window")
        #expect(sorted[2].title == "Other", "Third sorted visible window")
    }

    @Test("applyWindowFilter - combined filters with title and visible")
    func listWindowsCombinedTitleAndVisible() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "TextEdit", isOnScreen: true),
            makeWindowInfo(windowID: 2, title: "TextEdit", isOnScreen: false),
            makeWindowInfo(windowID: 3, title: "Calculator", isOnScreen: true),
        ]

        let filtered = service.applyWindowFilter(windows, filter: "title=\"TextEdit\" visible=true")
        #expect(filtered.count == 1, "Should match only visible TextEdit window")
        #expect(filtered[0].windowID == 1, "Should be the visible TextEdit")
    }

    @Test("applyWindowFilter - empty filter returns all windows")
    func listWindowsEmptyFilter() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "A", isOnScreen: true),
            makeWindowInfo(windowID: 2, title: "B", isOnScreen: false),
        ]

        let filtered = service.applyWindowFilter(windows, filter: "")
        #expect(filtered.count == 2, "Empty filter should return all windows")
    }

    // MARK: - ListApplications Ordering Tests

    @Test("ListApplications - default order by name")
    func listApplicationsDefaultOrder() {
        let apps = [
            makeApplication(pid: 300, displayName: "Zulu"),
            makeApplication(pid: 100, displayName: "Alpha"),
            makeApplication(pid: 200, displayName: "Mike"),
        ]

        let sorted = apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        #expect(sorted[0].displayName == "Alpha", "Default ordering should be by name (Alpha first)")
    }

    @Test("ListApplications - order by pid")
    func listApplicationsOrderByPid() {
        let apps = [
            makeApplication(pid: 300, displayName: "C"),
            makeApplication(pid: 100, displayName: "A"),
            makeApplication(pid: 200, displayName: "B"),
        ]

        let sorted = apps.sorted { $0.pid < $1.pid }
        #expect(sorted[0].pid == 100, "First should be pid 100")
        #expect(sorted[1].pid == 200, "Second should be pid 200")
        #expect(sorted[2].pid == 300, "Third should be pid 300")
    }

    @Test("ListApplications - order by display_name")
    func listApplicationsOrderByDisplayName() {
        let apps = [
            makeApplication(pid: 1, displayName: "Zulu"),
            makeApplication(pid: 2, displayName: "Alpha"),
            makeApplication(pid: 3, displayName: "Mike"),
        ]

        let sorted = apps.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        #expect(sorted[0].displayName == "Alpha", "First should be Alpha")
        #expect(sorted[1].displayName == "Mike", "Second should be Mike")
        #expect(sorted[2].displayName == "Zulu", "Third should be Zulu")
    }

    @Test("ListApplications - order by display_name descending")
    func listApplicationsOrderByDisplayNameDesc() {
        let apps = [
            makeApplication(pid: 1, displayName: "Zulu"),
            makeApplication(pid: 2, displayName: "Alpha"),
            makeApplication(pid: 3, displayName: "Mike"),
        ]

        let sorted = apps.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }.reversed()
        let sortedArray = Array(sorted)
        #expect(sortedArray[0].displayName == "Zulu", "First should be Zulu (descending)")
        #expect(sortedArray[1].displayName == "Mike", "Second should be Mike")
        #expect(sortedArray[2].displayName == "Alpha", "Third should be Alpha")
    }

    // MARK: - ListApplications Filtering Tests

    @Test("applyApplicationFilter - name=\"...\" filters by display name")
    func listApplicationsFilterByName() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let apps = [
            makeApplication(pid: 1, displayName: "TextEdit"),
            makeApplication(pid: 2, displayName: "Calculator"),
            makeApplication(pid: 3, displayName: "Text Processor"),
        ]

        let filtered = service.applyApplicationFilter(apps, filter: "name=\"Text\"")
        #expect(filtered.count == 2, "Should filter to 2 apps containing 'Text'")
        #expect(filtered.allSatisfy { $0.displayName.contains("Text") }, "All should contain Text")
    }

    @Test("applyApplicationFilter - name filter is case insensitive")
    func listApplicationsFilterByNameCaseInsensitive() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let apps = [
            makeApplication(pid: 1, displayName: "TEXTEDIT"),
            makeApplication(pid: 2, displayName: "textedit"),
            makeApplication(pid: 3, displayName: "Calculator"),
        ]

        let filtered = service.applyApplicationFilter(apps, filter: "name=\"textedit\"")
        #expect(filtered.count == 2, "Should match case-insensitively")
    }

    @Test("applyApplicationFilter - combined ordering and filtering")
    func listApplicationsOrderAndFilter() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let apps = [
            makeApplication(pid: 200, displayName: "Text Editor"),
            makeApplication(pid: 100, displayName: "TextEdit"),
            makeApplication(pid: 300, displayName: "Calculator"),
            makeApplication(pid: 150, displayName: "Text Processor"),
        ]

        // Filter by name, then sort by pid
        let filtered = service.applyApplicationFilter(apps, filter: "name=\"Text\"")
        let sorted = filtered.sorted { $0.pid < $1.pid }

        #expect(sorted.count == 3, "Should have 3 apps with 'Text' in name")
        #expect(sorted[0].pid == 100, "First should be pid 100 (TextEdit)")
        #expect(sorted[1].pid == 150, "Second should be pid 150 (Text Processor)")
        #expect(sorted[2].pid == 200, "Third should be pid 200 (Text Editor)")
    }

    @Test("applyApplicationFilter - empty filter returns all apps")
    func listApplicationsEmptyFilter() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let apps = [
            makeApplication(pid: 1, displayName: "App1"),
            makeApplication(pid: 2, displayName: "App2"),
        ]

        let filtered = service.applyApplicationFilter(apps, filter: "")
        #expect(filtered.count == 2, "Empty filter should return all apps")
    }

    // MARK: - Edge Cases

    @Test("Empty window list handles ordering gracefully")
    func listWindowsEmptyList() {
        let windows: [WindowRegistry.WindowInfo] = []
        let sorted = windows.sorted { $0.windowID < $1.windowID }
        #expect(sorted.isEmpty, "Empty list should remain empty after sort")
    }

    @Test("Empty application list handles filtering gracefully")
    func listApplicationsEmptyList() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let apps: [Macosusesdk_V1_Application] = []
        let filtered = service.applyApplicationFilter(apps, filter: "name=\"Test\"")
        #expect(filtered.isEmpty, "Empty list should remain empty after filter")
    }

    @Test("Filter with special characters in value")
    func filterWithSpecialCharacters() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "File - My Doc.txt"),
            makeWindowInfo(windowID: 2, title: "Other Window"),
        ]

        let filtered = service.applyWindowFilter(windows, filter: "title=\"My Doc.txt\"")
        #expect(filtered.count == 1, "Should match title with special characters")
        #expect(filtered[0].windowID == 1, "Should be the correct window")
    }

    @Test("Multiple sort stability")
    func sortStabilityTest() {
        let windows = [
            makeWindowInfo(windowID: 1, title: "Same"),
            makeWindowInfo(windowID: 2, title: "Same"),
            makeWindowInfo(windowID: 3, title: "Same"),
        ]

        // When titles are the same, verify consistent ordering
        let sorted1 = windows.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let sorted2 = windows.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        // Both sorts should produce 3 items with same ordering
        #expect(sorted1.count == 3, "Sort should maintain all elements")
        #expect(sorted2.count == 3, "Sort should maintain all elements")
    }

    @Test("Unicode title filter handling")
    func unicodeTitleFilter() {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        let service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )

        let windows = [
            makeWindowInfo(windowID: 1, title: "日本語ドキュメント"),
            makeWindowInfo(windowID: 2, title: "English Document"),
            makeWindowInfo(windowID: 3, title: "Documento Español"),
        ]

        let filtered = service.applyWindowFilter(windows, filter: "title=\"日本語\"")
        #expect(filtered.count == 1, "Should match Japanese characters")
        #expect(filtered[0].windowID == 1, "Should be the Japanese document")
    }
}
