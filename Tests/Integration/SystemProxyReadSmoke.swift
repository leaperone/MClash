import Foundation

@main
struct SystemProxyReadSmoke {
    static func main() async throws {
        let manager = SystemProxyManager()
        let snapshot = try await manager.captureSnapshot()
        print("System proxy read smoke passed: \(snapshot.services.count) enabled network services")
    }
}
