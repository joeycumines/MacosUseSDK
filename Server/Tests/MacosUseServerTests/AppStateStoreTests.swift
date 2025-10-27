import XCTest
@testable import MacosUseServer

/// Tests for the AppStateStore actor
final class AppStateStoreTests: XCTestCase {
    
    func testAddAndGetTarget() async {
        let store = AppStateStore()
        let target = TargetApplicationInfo(
            name: "targetApplications/123",
            pid: 123,
            appName: "TestApp"
        )
        
        await store.addTarget(target)
        let retrieved = await store.getTarget(pid: 123)
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.pid, 123)
        XCTAssertEqual(retrieved?.appName, "TestApp")
    }
    
    func testListTargets() async {
        let store = AppStateStore()
        let target1 = TargetApplicationInfo(name: "targetApplications/123", pid: 123, appName: "App1")
        let target2 = TargetApplicationInfo(name: "targetApplications/456", pid: 456, appName: "App2")
        
        await store.addTarget(target1)
        await store.addTarget(target2)
        
        let targets = await store.listTargets()
        XCTAssertEqual(targets.count, 2)
    }
    
    func testRemoveTarget() async {
        let store = AppStateStore()
        let target = TargetApplicationInfo(name: "targetApplications/123", pid: 123, appName: "TestApp")
        
        await store.addTarget(target)
        let removed = await store.removeTarget(pid: 123)
        
        XCTAssertNotNil(removed)
        XCTAssertEqual(removed?.pid, 123)
        
        let retrieved = await store.getTarget(pid: 123)
        XCTAssertNil(retrieved)
    }
    
    func testCurrentState() async {
        let store = AppStateStore()
        let target = TargetApplicationInfo(name: "targetApplications/123", pid: 123, appName: "TestApp")
        
        await store.addTarget(target)
        let state = await store.currentState()
        
        XCTAssertEqual(state.targets.count, 1)
        XCTAssertNotNil(state.targets[123])
    }
}
