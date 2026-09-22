/// Errors that can occur during file dialog automation
enum FileDialogError: Error, CustomStringConvertible {
    case invalidPath(String)
    case dialogCancelled
    case dialogTimeout
    case fileNotFound(String)
    case directoryNotFound(String)
    case permissionDenied(String)
    case invalidFileType
    case creationFailed(String)

    var description: String {
        switch self {
        case let .invalidPath(path):
            "Invalid path: \(path)"
        case .dialogCancelled:
            "Dialog was cancelled by user"
        case .dialogTimeout:
            "Dialog did not appear within timeout"
        case let .fileNotFound(path):
            "File not found: \(path)"
        case let .directoryNotFound(path):
            "Directory not found: \(path)"
        case let .permissionDenied(path):
            "Permission denied: \(path)"
        case .invalidFileType:
            "Invalid file type for operation"
        case let .creationFailed(reason):
            "Creation failed: \(reason)"
        }
    }
}
