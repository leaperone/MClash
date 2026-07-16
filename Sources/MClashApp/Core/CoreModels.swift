import Foundation

enum CoreRunState: Equatable, Sendable {
    case stopped
    case validating
    case starting
    case running(CoreSession)
    case stopping
    case failed(String)
}

struct CoreSession: Equatable, Sendable {
    let endpoint: URL
    let secret: String
    let version: String
    let startedAt: Date
}

struct CoreLogLine: Identifiable, Equatable, Sendable {
    enum Stream: String, Sendable {
        case standardOutput
        case standardError
        case supervisor
    }

    let id: UUID
    let timestamp: Date
    let stream: Stream
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stream: Stream,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stream = stream
        self.message = message
    }
}

enum CoreEvent: Sendable {
    case stateChanged(CoreRunState)
    case log(CoreLogLine)
}

struct CoreLaunchConfiguration: Equatable, Sendable {
    let binaryURL: URL
    let homeDirectory: URL
    let configURL: URL
    let controllerPort: UInt16
    let secret: String

    var controllerEndpoint: URL {
        URL(string: "http://127.0.0.1:\(controllerPort)")!
    }
}

enum CoreSupervisorError: LocalizedError, Equatable {
    case alreadyRunning
    case binaryNotFound(String)
    case binaryNotExecutable(String)
    case configurationNotFound(String)
    case configurationInvalid(String)
    case launchFailed(String)
    case readinessTimedOut

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "The proxy core is already running."
        case let .binaryNotFound(path):
            "MClash’s bundled proxy core is missing. Reinstall MClash. (\(path))"
        case let .binaryNotExecutable(path):
            "MClash’s bundled proxy core is not executable. Reinstall MClash. (\(path))"
        case let .configurationNotFound(path):
            "The active configuration was not found at \(path)."
        case let .configurationInvalid(details):
            "The configuration did not pass core validation.\n\(details)"
        case let .launchFailed(details):
            "The proxy core could not be launched.\n\(details)"
        case .readinessTimedOut:
            "The proxy core launched but did not become ready in time."
        }
    }
}
