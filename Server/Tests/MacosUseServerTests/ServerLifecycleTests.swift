import Darwin
import Foundation
@testable import MacosUseServer
import Testing

@Suite(.serialized)
struct ServerLifecycleTests {
    @Test
    func `shutdown signal begins drain and waits for server completion`() async throws {
        let serverRelease = AsyncStream.makeStream(of: Void.self)
        let shutdownStarted = AsyncStream.makeStream(of: Void.self)
        let cleanupRelease = AsyncStream.makeStream(of: Void.self)
        let signals = AsyncStream.makeStream(
            of: Int32.self,
            bufferingPolicy: .bufferingNewest(1),
        )
        let recorder = LifecycleShutdownRecorder()
        let mutationGate = PhysicalDesktopMutationGate()
        let serverTask = Task<Void, any Error> {
            var iterator = serverRelease.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let lifecycleTask = Task {
            try await waitForServerTermination(
                serverTask: serverTask,
                shutdownSignals: signals.stream,
                beginGracefulShutdown: {
                    await mutationGate.beginDraining()
                    recorder.record()
                    shutdownStarted.continuation.yield(())
                    shutdownStarted.continuation.finish()
                    var iterator = cleanupRelease.stream.makeAsyncIterator()
                    _ = await iterator.next()
                },
            )
        }

        signals.continuation.yield(SIGTERM)
        var shutdownIterator = shutdownStarted.stream.makeAsyncIterator()
        _ = await shutdownIterator.next()

        #expect(recorder.snapshot() == 1)
        #expect(await mutationGate.lifecycleState() == .drained)

        serverRelease.continuation.yield(())
        serverRelease.continuation.finish()
        cleanupRelease.continuation.yield(())
        cleanupRelease.continuation.finish()
        try await lifecycleTask.value

        do {
            try await mutationGate.withExclusiveOperation {}
            Issue.record("Expected shutdown to close physical mutation admission")
        } catch let error as PhysicalDesktopMutationError {
            #expect(error == .admissionClosed)
        }
        signals.continuation.finish()
    }

    @Test
    func `serve failure propagates without pretending graceful shutdown`() async throws {
        let signals = AsyncStream.makeStream(of: Int32.self)
        let recorder = LifecycleShutdownRecorder()
        let serverTask = Task<Void, any Error> {
            throw InjectedServerLifecycleError.serveFailure
        }

        do {
            try await waitForServerTermination(
                serverTask: serverTask,
                shutdownSignals: signals.stream,
                beginGracefulShutdown: { recorder.record() },
            )
            Issue.record("Expected serve failure")
        } catch InjectedServerLifecycleError.serveFailure {
            // Expected exact production status propagation.
        }

        #expect(recorder.snapshot() == 0)
        signals.continuation.finish()
    }

    @Test
    @MainActor
    func `preexisting Unix path is rejected without mutation`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("server.sock")
        let marker = Data("preserve-me".utf8)
        try marker.write(to: path)

        let owner = UnixSocketPathOwner(path: path.path)
        #expect(throws: UnixSocketPathError.self) {
            try owner.prepareForBind()
        }
        #expect(try Data(contentsOf: path) == marker)
    }

    @Test
    @MainActor
    func `overlong Unix path is rejected before bind`() {
        let owner = UnixSocketPathOwner(path: "/tmp/" + String(repeating: "x", count: 200))

        #expect(throws: UnixSocketPathError.self) {
            try owner.prepareForBind()
        }
    }

    @Test
    @MainActor
    func `absent Unix path passes unmanaged-path validation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        let owner = UnixSocketPathOwner(path: path)
        #expect(try owner.prepareForBind() == false)
    }

    @Test
    @MainActor
    func `direct Unix pathname binding creates an owned listener`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        let owner = UnixSocketPathOwner(path: path)
        let descriptor = try owner.makeListeningSocket()
        defer {
            _ = Darwin.close(descriptor)
            _ = path.withCString { unlink($0) }
        }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(canConnect(to: path) == true)
    }

    @Test
    @MainActor
    func `activated node validation accepts owner-private socket node`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        let listener = try bindListeningSocket(at: path)
        defer {
            _ = Darwin.close(listener)
            _ = path.withCString { unlink($0) }
        }
        // launchd creates the node with SockPathMode 0600; the test fixture
        // must set the same mode since the test process umask is 022.
        #expect(path.withCString { chmod($0, 0o600) } == 0)
        var nodeStatus = stat()
        #expect(path.withCString { lstat($0, &nodeStatus) } == 0)
        #expect(nodeStatus.st_uid == geteuid())
        #expect(nodeStatus.st_mode & mode_t(0o777) == mode_t(0o600))

        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(probe >= 0)
        defer { _ = Darwin.close(probe) }
        // Must not throw for a node owned by the current user with 0600 mode,
        // even though fstat on a bare descriptor reports synthetic metadata.
        try UnixSocketPathOwner.validateActivatedNode(
            nodeStatus,
            path: path,
            descriptorForCleanup: probe,
        )
    }

    @Test
    @MainActor
    func `activated node validation rejects wrong-mode node`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        let listener = try bindListeningSocket(at: path)
        defer {
            _ = Darwin.close(listener)
            _ = path.withCString { unlink($0) }
        }
        #expect(path.withCString { chmod($0, 0o644) } == 0)
        var nodeStatus = stat()
        #expect(path.withCString { lstat($0, &nodeStatus) } == 0)

        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(probe >= 0)
        guard probe >= 0 else { return }
        // Validation owns and closes the descriptor on rejection. Do not probe
        // the raw descriptor number afterward: concurrent tests may reuse it.
        #expect(throws: UnixSocketPathError.self) {
            try UnixSocketPathOwner.validateActivatedNode(
                nodeStatus,
                path: path,
                descriptorForCleanup: probe,
            )
        }
    }

    @Test
    @MainActor
    func `launchd activation failure leaves configured pathname untouched`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let owner = UnixSocketPathOwner(path: path)

        #expect(throws: UnixSocketPathError.self) {
            _ = try owner.activateLaunchdSocket(name: "missing-listener")
        }
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test
    @MainActor
    func `missing launchd activation maps to actionable fail-closed error`() {
        let error = UnixSocketPathError.activationFailure(path: "/tmp/macosuse.sock", code: ENOENT)
        #expect(error == .launchdActivationRequired("/tmp/macosuse.sock"))
        #expect(error.localizedDescription.contains("must be activated by launchd"))
        #expect(error.localizedDescription.contains("loopback TCP"))

        let other = UnixSocketPathError.activationFailure(path: "/tmp/macosuse.sock", code: EACCES)
        #expect(other == .activatedSocketUnavailable(path: "/tmp/macosuse.sock", code: EACCES))
    }

    @Test
    @MainActor
    func `cleanup never mutates configured Unix pathname`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let marker = Data("preserve-me".utf8)
        try marker.write(to: URL(fileURLWithPath: path))
        let owner = UnixSocketPathOwner(path: path)

        #expect(owner.cleanup() == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == marker)
    }

    @Test
    @MainActor
    func `prebound Unix socket refuses an existing pathname without mutation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let marker = Data("preserve-me".utf8)
        try marker.write(to: URL(fileURLWithPath: path))

        let owner = UnixSocketPathOwner(path: path)
        #expect(throws: UnixSocketPathError.self) {
            _ = try owner.makeListeningSocket()
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == marker)
    }

    @Test
    @MainActor
    func `stale Unix socket is refused without mutation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        let staleDescriptor = try bindListeningSocket(at: path)
        // Simulate a crash or reboot: the listener is gone but the pathname remains.
        _ = Darwin.close(staleDescriptor)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(canConnect(to: path) == false)

        let owner = UnixSocketPathOwner(path: path)
        #expect(throws: UnixSocketPathError.self) {
            try owner.prepareForBind()
        }
        // A later owner must not delete a path it did not create; deployment
        // cleanup or an operator can remove the stale pathname explicitly.
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test
    @MainActor
    func `live Unix socket is refused without mutation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        let liveDescriptor = try bindListeningSocket(at: path)
        defer {
            _ = Darwin.close(liveDescriptor)
            _ = path.withCString { unlink($0) }
        }
        #expect(canConnect(to: path))

        let owner = UnixSocketPathOwner(path: path)
        #expect(throws: UnixSocketPathError.self) {
            try owner.prepareForBind()
        }
        // The live listener still owns the path: no unlink, still connectable.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(canConnect(to: path))
    }

    @Test
    @MainActor
    func `symlink Unix path is refused without following`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let marker = Data("preserve-me".utf8)
        try marker.write(to: target)
        let link = directory.appendingPathComponent("s.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let owner = UnixSocketPathOwner(path: link.path)
        #expect(throws: UnixSocketPathError.self) {
            try owner.prepareForBind()
        }
        #expect(try Data(contentsOf: target) == marker)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test
    @MainActor
    func `directory Unix path is refused without mutation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subdir = directory.appendingPathComponent("s.sock", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: false)

        let owner = UnixSocketPathOwner(path: subdir.path)
        #expect(throws: UnixSocketPathError.self) {
            try owner.prepareForBind()
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: subdir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

private func makeShortSocketDirectory() throws -> URL {
    let directory = URL(
        fileURLWithPath: "/tmp/macosuse-\(UUID().uuidString.prefix(8))",
        isDirectory: true,
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeUnixAddress(path: String) -> sockaddr_un? {
    let maximumBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    guard path.utf8.count <= maximumBytes else {
        return nil
    }
    var address = sockaddr_un()
    memset(&address, 0, MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: maximumBytes + 1) { buffer in
                _ = strncpy(buffer, source, maximumBytes)
            }
        }
    }
    return address
}

private func bindListeningSocket(at path: String) throws -> Int32 {
    _ = path.withCString { unlink($0) }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
    guard var address = makeUnixAddress(path: path) else {
        _ = Darwin.close(descriptor)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG), userInfo: nil)
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0, Darwin.listen(descriptor, 5) == 0 else {
        let code = Int(errno)
        _ = Darwin.close(descriptor)
        _ = path.withCString { unlink($0) }
        throw NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: nil)
    }
    return descriptor
}

private func canConnect(to path: String) -> Bool {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        return false
    }
    defer { _ = Darwin.close(descriptor) }
    guard var address = makeUnixAddress(path: path) else {
        return false
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return result == 0
}

private enum InjectedServerLifecycleError: Error {
    case serveFailure
}

private final class LifecycleShutdownRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
