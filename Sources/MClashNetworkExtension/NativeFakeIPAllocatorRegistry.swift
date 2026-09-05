import Foundation
import MClashNetworkShared

/// Process-wide candidate holder shared by DNS and transparent providers.
/// Replacement is a single lock-protected pointer swap; callers construct and
/// validate candidates before replacing the current one.
final class NativeFakeIPAllocatorRegistry: @unchecked Sendable {
    static let shared = NativeFakeIPAllocatorRegistry()

    private let lock = NSLock()
    private var current: NativeFakeIPAllocator?

    func snapshot() -> NativeFakeIPAllocator? {
        lock.withLock { current }
    }

    @discardableResult
    func replace(with candidate: NativeFakeIPAllocator?) -> NativeFakeIPAllocator? {
        lock.withLock {
            let previous = current
            current = candidate
            return previous
        }
    }

    func clear() {
        _ = replace(with: nil)
    }
}
