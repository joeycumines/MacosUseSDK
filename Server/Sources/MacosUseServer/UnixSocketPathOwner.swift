import Darwin
import Foundation

/// A launchd-activated Unix socket descriptor is the endpoint authority. The
/// pathname is configured by launchd, while the descriptor is transferred to
/// gRPC without a second pathname lookup.
enum UnixSocketPathError: Error, LocalizedError {
    case pathTooLong(path: String, actualBytes: Int, maximumBytes: Int)
    case pathAlreadyExists(String)
    case launchdActivationRequired(String)
    case activatedSocketUnavailable(path: String, code: Int32)
    case activatedSocketCount(path: String, actual: Int)
    case activatedDescriptorIsNotSocket(String)
    case activatedDescriptorHasWrongOwner(path: String, actual: uid_t, expected: uid_t)
    case activatedDescriptorHasWrongPermissions(path: String, actual: mode_t)
    case activatedDescriptorHasWrongDomain(path: String, actual: Int32)
    case activatedDescriptorHasWrongPath(path: String, actual: String)
    case activatedDescriptorHasWrongType(path: String, actual: Int32)
    case activatedDescriptorIsNotListening(String)
    case systemCall(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .pathTooLong(path, actualBytes, maximumBytes):
            "Unix socket path \(path) is \(actualBytes) bytes; maximum is \(maximumBytes)"
        case let .pathAlreadyExists(path):
            "refusing unmanaged Unix socket path \(path): path already exists"
        case let .launchdActivationRequired(path):
            "Unix socket path \(path) must be activated by launchd; direct pathname binding is disabled"
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
        case let .activatedDescriptorHasWrongPath(path, actual):
            "launchd activated socket path \(actual) does not match configured path \(path)"
        case let .activatedDescriptorHasWrongType(path, actual):
            "launchd socket path \(path) has socket type \(actual); expected SOCK_STREAM"
        case let .activatedDescriptorIsNotListening(path):
            "launchd socket path \(path) is not a listening socket"
        case let .systemCall(operation, path, code):
            "\(operation) failed for Unix socket path \(path): errno \(code)"
        }
    }
}

struct UnixSocketIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

@MainActor
final class UnixSocketPathOwner {
    let path: String
    private var standaloneIdentity: UnixSocketIdentity?

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
            _ = path.withCString { unlink($0) }
            throw UnixSocketPathError.systemCall(operation: "listen", path: path, code: code)
        }
        var status = stat()
        guard path.withCString({ lstat($0, &status) == 0 }) else {
            let code = errno
            _ = Darwin.close(descriptor)
            _ = path.withCString { unlink($0) }
            throw UnixSocketPathError.systemCall(operation: "lstat", path: path, code: code)
        }
        standaloneIdentity = UnixSocketIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
        )
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
            throw UnixSocketPathError.activatedSocketUnavailable(path: path, code: Int32(result))
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
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.systemCall(operation: "fstat", path: path, code: code)
        }
        guard status.st_mode & mode_t(0o170000) == mode_t(0o140000) else {
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.activatedDescriptorIsNotSocket(path)
        }
        let expectedOwner = geteuid()
        guard status.st_uid == expectedOwner else {
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.activatedDescriptorHasWrongOwner(
                path: path,
                actual: status.st_uid,
                expected: expectedOwner,
            )
        }
        let permissions = status.st_mode & 0o777
        guard permissions == 0o600 else {
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.activatedDescriptorHasWrongPermissions(
                path: path,
                actual: permissions,
            )
        }
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
        var unixAddress = sockaddr_un()
        let addressBytes = min(
            Int(socketAddressLength),
            MemoryLayout<sockaddr_un>.size,
        )
        withUnsafeMutableBytes(of: &unixAddress) { destination in
            withUnsafeBytes(of: &socketAddress) { source in
                destination.copyBytes(from: source.prefix(addressBytes))
            }
        }
        let sunPathSize = MemoryLayout.size(ofValue: unixAddress.sun_path)
        // sockaddr length includes the leading length/family bytes. Never use
        // String(cString:) on the full sun_path tuple: getsockname may return a
        // truncated or unterminated address. Decode only bytes covered by the
        // returned length and stop at an explicit NUL.
        let sunPathBytes = max(
            0,
            min(sunPathSize, Int(socketAddressLength) - 2),
        )
        let activatedPath: String = withUnsafeBytes(of: unixAddress.sun_path) { rawBytes in
            let bounded = rawBytes.prefix(sunPathBytes)
            let terminator = bounded.firstIndex(of: 0) ?? bounded.endIndex
            return String(decoding: bounded[..<terminator], as: UTF8.self)
        }
        guard activatedPath == path else {
            _ = Darwin.close(descriptor)
            throw UnixSocketPathError.activatedDescriptorHasWrongPath(
                path: path,
                actual: activatedPath,
            )
        }
        try validateSocketOption(
            descriptor: descriptor,
            option: SO_TYPE,
            expected: Int32(SOCK_STREAM),
            failure: { actual in
                UnixSocketPathError.activatedDescriptorHasWrongType(path: path, actual: actual)
            },
        )
        try validateSocketOption(
            descriptor: descriptor,
            option: SO_ACCEPTCONN,
            expected: 1,
            failure: { _ in
                UnixSocketPathError.activatedDescriptorIsNotListening(path)
            },
        )
        return descriptor
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

    /// Cleans up only a pathname created by this owner in standalone mode.
    /// Launchd-owned descriptors intentionally leave their pathname untouched.
    @discardableResult
    func cleanup() throws -> Bool {
        guard let expectedIdentity = standaloneIdentity else { return false }
        var status = stat()
        guard path.withCString({ lstat($0, &status) == 0 }) else {
            if errno == ENOENT {
                standaloneIdentity = nil
                return true
            }
            throw UnixSocketPathError.systemCall(operation: "lstat", path: path, code: errno)
        }
        let current = UnixSocketIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        guard current == expectedIdentity else {
            throw UnixSocketPathError.pathAlreadyExists(path)
        }
        guard path.withCString({ unlink($0) == 0 }) || errno == ENOENT else {
            throw UnixSocketPathError.systemCall(operation: "unlink", path: path, code: errno)
        }
        standaloneIdentity = nil
        return true
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
