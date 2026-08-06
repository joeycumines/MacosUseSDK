import Darwin
import Foundation

struct UnixSocketIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

enum UnixSocketPathError: Error, LocalizedError {
    case pathTooLong(path: String, actualBytes: Int, maximumBytes: Int)
    case pathAlreadyExists(String)
    case createdPathIsNotSocket(String)
    case createdPathHasWrongOwner(path: String, actual: uid_t, expected: uid_t)
    case createdPathHasWrongLinkCount(path: String, actual: nlink_t)
    case createdPathChanged(String)
    case createdPathTimedOut(String)
    case createdPathHasWrongPermissions(path: String, actual: mode_t)
    case systemCall(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .pathTooLong(path, actualBytes, maximumBytes):
            "Unix socket path \(path) is \(actualBytes) bytes; maximum is \(maximumBytes)"
        case let .pathAlreadyExists(path):
            "refusing Unix socket path \(path): path already exists"
        case let .createdPathIsNotSocket(path):
            "Unix socket path \(path) is not a socket"
        case let .createdPathHasWrongOwner(path, actual, expected):
            "Unix socket path \(path) is owned by uid \(actual); expected \(expected)"
        case let .createdPathHasWrongLinkCount(path, actual):
            "Unix socket path \(path) has \(actual) links; expected exactly one"
        case let .createdPathChanged(path):
            "Unix socket path \(path) changed identity"
        case let .createdPathTimedOut(path):
            "Unix socket path \(path) was not created before the startup deadline"
        case let .createdPathHasWrongPermissions(path, actual):
            "Unix socket path \(path) has permissions 0\(String(actual, radix: 8)); expected 0600"
        case let .systemCall(operation, path, code):
            "\(operation) failed for Unix socket path \(path): errno \(code)"
        }
    }
}

@MainActor
final class UnixSocketPathOwner {
    let path: String

    private var identity: UnixSocketIdentity?

    init(path: String) {
        self.path = path
    }

    func prepareForBind() throws {
        let pathLength = path.utf8.count
        guard pathLength <= Self.maximumPathBytes else {
            throw UnixSocketPathError.pathTooLong(
                path: path,
                actualBytes: pathLength,
                maximumBytes: Self.maximumPathBytes,
            )
        }
        if try Self.readMetadata(path: path) != nil {
            throw UnixSocketPathError.pathAlreadyExists(path)
        }
    }

    func claimCreatedSocket(
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(10),
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while true {
            try Task.checkCancellation()
            if let metadata = try Self.readMetadata(path: path) {
                try Self.validate(metadata: metadata, path: path)
                let expectedIdentity = metadata.identity
                let chmodResult = path.withCString { pointer in
                    fchmodat(AT_FDCWD, pointer, 0o600, AT_SYMLINK_NOFOLLOW)
                }
                guard chmodResult == 0 else {
                    throw UnixSocketPathError.systemCall(
                        operation: "fchmodat",
                        path: path,
                        code: errno,
                    )
                }
                guard let verified = try Self.readMetadata(path: path) else {
                    throw UnixSocketPathError.createdPathChanged(path)
                }
                try Self.validate(metadata: verified, path: path)
                guard verified.identity == expectedIdentity else {
                    throw UnixSocketPathError.createdPathChanged(path)
                }
                guard verified.permissions == 0o600 else {
                    throw UnixSocketPathError.createdPathHasWrongPermissions(
                        path: path,
                        actual: verified.permissions,
                    )
                }
                identity = expectedIdentity
                return
            }

            guard clock.now < deadline else {
                throw UnixSocketPathError.createdPathTimedOut(path)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    @discardableResult
    func cleanup() throws -> Bool {
        guard let expectedIdentity = identity else {
            return false
        }
        guard let metadata = try Self.readMetadata(path: path) else {
            identity = nil
            return true
        }
        try Self.validate(metadata: metadata, path: path)
        guard metadata.identity == expectedIdentity else {
            throw UnixSocketPathError.createdPathChanged(path)
        }
        let unlinkResult = path.withCString { pointer in
            unlink(pointer)
        }
        guard unlinkResult == 0 || errno == ENOENT else {
            throw UnixSocketPathError.systemCall(
                operation: "unlink",
                path: path,
                code: errno,
            )
        }
        identity = nil
        return true
    }

    private struct Metadata {
        let identity: UnixSocketIdentity
        let mode: mode_t
        let owner: uid_t
        let linkCount: nlink_t

        var permissions: mode_t {
            mode & 0o777
        }
    }

    private static let maximumPathBytes = MemoryLayout.size(
        ofValue: sockaddr_un().sun_path,
    ) - 1

    private static func readMetadata(path: String) throws -> Metadata? {
        var status = stat()
        let result = path.withCString { pointer in
            lstat(pointer, &status)
        }
        if result == 0 {
            return Metadata(
                identity: UnixSocketIdentity(
                    device: UInt64(status.st_dev),
                    inode: UInt64(status.st_ino),
                ),
                mode: status.st_mode,
                owner: status.st_uid,
                linkCount: status.st_nlink,
            )
        }
        if errno == ENOENT {
            return nil
        }
        throw UnixSocketPathError.systemCall(
            operation: "lstat",
            path: path,
            code: errno,
        )
    }

    private static func validate(metadata: Metadata, path: String) throws {
        guard metadata.mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw UnixSocketPathError.createdPathIsNotSocket(path)
        }
        let expectedOwner = geteuid()
        guard metadata.owner == expectedOwner else {
            throw UnixSocketPathError.createdPathHasWrongOwner(
                path: path,
                actual: metadata.owner,
                expected: expectedOwner,
            )
        }
        guard metadata.linkCount == 1 else {
            throw UnixSocketPathError.createdPathHasWrongLinkCount(
                path: path,
                actual: metadata.linkCount,
            )
        }
    }
}
