import Darwin
import Foundation

/// A launchd-activated Unix socket descriptor is the endpoint authority. The
/// pathname is configured by launchd, while the descriptor is transferred to
/// gRPC without a second pathname lookup.
enum UnixSocketPathError: Error, LocalizedError, Equatable {
    case pathTooLong(path: String, actualBytes: Int, maximumBytes: Int)
    case pathAlreadyExists(String)
    case launchdActivationRequired(String)
    case activatedSocketUnavailable(path: String, code: Int32)
    case activatedSocketCount(path: String, actual: Int)
    case activatedDescriptorIsNotSocket(String)
    case activatedDescriptorHasWrongOwner(path: String, actual: uid_t, expected: uid_t)
    case activatedDescriptorHasWrongPermissions(path: String, actual: mode_t)
    case activatedDescriptorHasWrongDomain(path: String, actual: Int32)
    case activatedDescriptorHasWrongType(path: String, actual: Int32)
    case systemCall(operation: String, path: String, code: Int32)

    static func activationFailure(path: String, code: Int32) -> UnixSocketPathError {
        if code == ENOENT || code == ESRCH {
            return .launchdActivationRequired(path)
        }
        return .activatedSocketUnavailable(path: path, code: code)
    }

    var errorDescription: String? {
        switch self {
        case let .pathTooLong(path, actualBytes, maximumBytes):
            "Unix socket path \(path) is \(actualBytes) bytes; maximum is \(maximumBytes)"
        case let .pathAlreadyExists(path):
            "refusing unmanaged Unix socket path \(path): path already exists"
        case let .launchdActivationRequired(path):
            "Unix socket path \(path) must be activated by launchd; direct pathname binding is disabled; unset GRPC_UNIX_SOCKET and use loopback TCP for manual execution"
        case let .activatedSocketUnavailable(path, code):
            "launchd socket activation failed for Unix socket path \(path): errno \(code)"
        case let .activatedSocketCount(path, actual):
            "launchd returned \(actual) descriptors for Unix socket path \(path); expected exactly one"
        case let .activatedDescriptorIsNotSocket(path):
            "launchd activated a non-socket descriptor for Unix socket path \(path)"
        case let .activatedDescriptorHasWrongOwner(path, actual, expected):
            "launchd socket path \(path) is owned by uid \(actual); expected \(expected)"
        case let .activatedDescriptorHasWrongPermissions(path, actual):
            "launchd socket path \(path) has permissions 0\(String(actual, radix: 8)); expected 0600"
        case let .activatedDescriptorHasWrongDomain(path, actual):
            "launchd socket path \(path) has socket domain \(actual); expected AF_UNIX"
        case let .activatedDescriptorHasWrongType(path, actual):
            "launchd socket path \(path) has socket type \(actual); expected SOCK_STREAM"
        case let .systemCall(operation, path, code):
            "\(operation) failed for Unix socket path \(path): errno \(code)"
        }
    }
}

@MainActor
final class UnixSocketPathOwner {
    let path: String

    init(path: String) {
        self.path = path
    }

    /// Validates an unmanaged configured pathname without mutating it.
    ///
    /// Production Unix startup does not use this check to admit a listener:
    /// launchd creates and owns the socket pathname. This method remains useful
    /// for rejecting accidental direct binding and for preserving existing
    /// paths in callers that validate configuration before launchd activation.
    @discardableResult
    func prepareForBind() throws -> Bool {
        try validatePathLength()
        guard try Self.pathExists(path) == false else {
            throw UnixSocketPathError.pathAlreadyExists(path)
        }
        return false
    }

    /// Creates a listener for standalone/manual execution. The descriptor is
    /// handed directly to gRPC, so no second pathname lookup is performed after
    /// bind. Existing pathnames are never removed; a concurrent creator causes
    /// bind to fail closed rather than allowing this process to claim its node.
    func makeListeningSocket(backlog: Int32 = 128) throws -> Int32 {
        try validatePathLength()
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketPathError.systemCall(operation: "socket", path: path, code: errno)
        }
        var address = sockaddr_un()
        memset(&address, 0, MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: Self.maximumPathBytes + 1) { buffer in
                    _ = strncpy(buffer, source, Self.maximumPathBytes)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.systemCall(operation: "bind", path: path, code: code)
        }
        guard Darwin.listen(descriptor, backlog) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            // Do not unlink by pathname after a failed listen: another process
            // may have replaced the node while this descriptor was open.
            throw UnixSocketPathError.systemCall(operation: "listen", path: path, code: code)
        }
        var status = stat()
        guard path.withCString({ lstat($0, &status) == 0 }) else {
            let code = errno
            _ = Darwin.close(descriptor)
            // The pathname is mutable and is not safe to remove after a failed
            // lookup; leave cleanup to the owner/operator rather than deleting
            // a replacement node.
            throw UnixSocketPathError.systemCall(operation: "lstat", path: path, code: code)
        }
        return descriptor
    }

    /// Retrieves the descriptor launchd created for the configured socket.
    /// launchd owns the pathname and hands this already-bound/listening
    /// descriptor to the process; the caller transfers it to gRPC, which then
    /// owns and closes it. No pathname identity comparison or unlink is needed.
    func activateLaunchdSocket(name: String) throws -> Int32 {
        try validatePathLength()
        var descriptors: UnsafeMutablePointer<Int32>?
        var count = 0
        let result = name.withCString { socketName in
            withUnsafeMutablePointer(to: &descriptors) { descriptorPointer in
                descriptorPointer.withMemoryRebound(
                    to: UnsafeMutablePointer<Int32>.self,
                    capacity: 1,
                ) { reboundPointer in
                    launch_activate_socket(socketName, reboundPointer, &count)
                }
            }
        }
        guard result == 0 else {
            if let descriptors {
                if count > 0 {
                    for index in 0 ..< count {
                        _ = Darwin.close(descriptors[index])
                    }
                }
                free(descriptors)
            }
            throw UnixSocketPathError.activationFailure(path: path, code: Int32(result))
        }
        guard count >= 0, let descriptors else {
            if let descriptors {
                free(descriptors)
            }
            throw UnixSocketPathError.activatedSocketCount(path: path, actual: count)
        }
        defer { free(descriptors) }
        guard count == 1 else {
            for index in 0 ..< count {
                _ = Darwin.close(descriptors[index])
            }
            throw UnixSocketPathError.activatedSocketCount(path: path, actual: count)
        }

        let descriptor = descriptors[0]
        // Owner/mode come from the filesystem node launchd created, read with
        // lstat (never follows symlinks). Darwin AF_UNIX descriptor metadata
        // is synthetic: fstat on a launchd-activated descriptor reports the
        // creator's credentials rather than the node owner/mode, so it must
        // not be used for those checks.
        var nodeStatus = stat()
        guard path.withCString({ lstat($0, &nodeStatus) == 0 }) else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.systemCall(operation: "lstat", path: path, code: code)
        }
        try Self.validateActivatedNode(nodeStatus, path: path, descriptorForCleanup: descriptor)
        // The fstat file-type bits still identify the activated descriptor
        // itself as a socket; domain and type are validated on the descriptor
        // below. Listening state is launchd's SockType=Stream guarantee; Darwin
        // AF_UNIX sockets do not expose SO_ACCEPTCONN through getsockopt
        // (ENOPROTOOPT), so it cannot be re-verified here.
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.systemCall(operation: "fstat", path: path, code: code)
        }
        guard descriptorStatus.st_mode & mode_t(0o170000) == mode_t(0o140000) else {
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.activatedDescriptorIsNotSocket(path)
        }
        // launchd binds the activated descriptor to an internal pathname such
        // as /var/run/com.apple.launchd.<token>/Listener, so getsockname does
        // NOT return the configured SockPathName. Descriptor authority comes
        // from launch_activate_socket("Listener") itself, and the client-facing
        // node was already validated by lstat above. Only the address family is
        // checked here.
        var socketAddress = sockaddr_storage()
        var socketAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        guard getsockname(
            descriptor,
            withUnsafeMutablePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
            },
            &socketAddressLength,
        ) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.systemCall(operation: "getsockname", path: path, code: code)
        }
        let socketDomain = Int32(socketAddress.ss_family)
        guard socketDomain == Int32(AF_UNIX) else {
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.activatedDescriptorHasWrongDomain(path: path, actual: socketDomain)
        }
        try validateSocketOption(
            descriptor: descriptor,
            option: SO_TYPE,
            expected: Int32(SOCK_STREAM),
            failure: { actual in
                UnixSocketPathError.activatedDescriptorHasWrongType(path: path, actual: actual)
            },
        )
        // Pre-condition the descriptor for SwiftNIO. NIO's ServerSocketChannel
        // init calls BaseSocket.init (ignoreSIGPIPE via F_SETNOSIGPIPE) then
        // ServerSocket(socket: setNonBlocking: true) (F_SETFL O_NONBLOCK).
        // Launchd-activated descriptors may return EINVAL for these fcntl
        // operations if not already set, causing NIOFcntlFailedError which
        // propagates as a fatal transportError. Setting them here via Darwin
        // fcntl before NIO touches the descriptor prevents the EINVAL.
        let fl = fcntl(descriptor, F_GETFL)
        guard fl != -1 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.systemCall(operation: "F_GETFL", path: path, code: code)
        }
        if (fl & O_NONBLOCK) == 0 {
            guard fcntl(descriptor, F_SETFL, fl | O_NONBLOCK) != -1 else {
                let code = errno
                _ = Darwin.close(descriptor)
                throw UnixSocketPathError.systemCall(operation: "F_SETFL O_NONBLOCK", path: path, code: code)
            }
        }
        // F_SETNOSIGPIPE: ignore EINVAL since some launchd socket types do not
        // support it, and NIO's ignoreSIGPIPE will also fail fatally if we
        // don't suppress it here.
        if fcntl(descriptor, F_SETNOSIGPIPE, 1) == -1, errno != EINVAL {
            let code = errno
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.systemCall(operation: "F_SETNOSIGPIPE", path: path, code: code)
        }
        return descriptor
    }

    /// Validates the launchd-created socket node: current-user owner, 0600
    /// permissions, and not a symlink. Closes the passed descriptor and
    /// throws on any mismatch.
    ///
    /// Internal (not private) so lifecycle tests can prove owner/mode are
    /// read from the pathname node rather than synthetic descriptor metadata.
    static func validateActivatedNode(
        _ nodeStatus: stat,
        path: String,
        descriptorForCleanup descriptor: Int32,
    ) throws {
        guard nodeStatus.st_mode & mode_t(0o170000) == mode_t(0o140000) else {
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.activatedDescriptorIsNotSocket(path)
        }
        let expectedOwner = geteuid()
        guard nodeStatus.st_uid == expectedOwner else {
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.activatedDescriptorHasWrongOwner(
                path: path,
                actual: nodeStatus.st_uid,
                expected: expectedOwner,
            )
        }
        let permissions = nodeStatus.st_mode & 0o777
        guard permissions == 0o600 else {
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.activatedDescriptorHasWrongPermissions(
                path: path,
                actual: permissions,
            )
        }
    }

    private func validateSocketOption(
        descriptor: Int32,
        option: Int32,
        expected: Int32,
        failure: (Int32) -> UnixSocketPathError,
    ) throws {
        var actual: Int32 = 0
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, option, &actual, &optionLength) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.systemCall(operation: "getsockopt", path: path, code: code)
        }
        guard actual == expected else {
            _ = Darwin.close(descriptor)
            throw failure(actual)
        }
    }

    /// Leaves the configured pathname untouched during shutdown. launchd owns
    /// the pathname and the transport owner closes the transferred descriptor.
    @discardableResult
    func cleanup() -> Bool {
        false
    }

    private static let maximumPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    private func validatePathLength() throws {
        let length = path.utf8.count
        guard length <= Self.maximumPathBytes else {
            throw UnixSocketPathError.pathTooLong(
                path: path,
                actualBytes: length,
                maximumBytes: Self.maximumPathBytes,
            )
        }
    }

    private static func pathExists(_ path: String) throws -> Bool {
        var status = stat()
        let result = path.withCString { lstat($0, &status) }
        if result == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw UnixSocketPathError.systemCall(operation: "lstat", path: path, code: errno)
    }
}
