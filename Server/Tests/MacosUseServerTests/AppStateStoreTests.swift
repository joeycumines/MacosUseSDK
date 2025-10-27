import XCTest
import MacosUseSDKProtos
@testable import MacosUseServer

/// Tests for the AppStateStore actor
final class AppStateStoreTests: XCTestCase {
    
    func testAddAndGetTarget() async {
        let store = AppStateStore()
        let target = Macosusesdk_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "TestApp"
        }
        
        await store.addTarget(target)
        let retrieved = await store.getTarget(pid: 123)
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.pid, 123)
        XCTAssertEqual(retrieved?.displayName, "TestApp")
    }
    
    func testListTargets() async {
        let store = AppStateStore()
        let target1 = Macosusesdk_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "App1"
        }
        let target2 = Macosusesdk_V1_Application.with {
            $0.name = "applications/456"
            $0.pid = 456
            $0.displayName = "App2"
        }
        
        await store.addTarget(target1)
        await store.addTarget(target2)
        
        let targets = await store.listTargets()
        XCTAssertEqual(targets.count, 2)
    }
    
    func testRemoveTarget() async {
        let store = AppStateStore()
        let target = Macosusesdk_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "TestApp"
        }
        
        await store.addTarget(target)
        let removed = await store.removeTarget(pid: 123)
        
        XCTAssertNotNil(removed)
        XCTAssertEqual(removed?.pid, 123)
        
        let retrieved = await store.getTarget(pid: 123)
        XCTAssertNil(retrieved)
    }
    
    func testCurrentState() async {
        let store = AppStateStore()
        let target = Macosusesdk_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "TestApp"
        }
        
        await store.addTarget(target)
        let state = await store.currentState()
        
        XCTAssertEqual(state.applications.count, 1)
        XCTAssertNotNil(state.applications[123])
    }
