import Foundation
import MClashNetworkShared

enum NativeFakeIPFlowDestinationResolution: Equatable, Sendable {
    case notFakeIP
    case resolved(endpoint: FlowRemoteEndpoint, hostname: String)
    case unavailable
}

enum NativeFakeIPFlowDestinationResolver {
    static func unavailableDecision() -> FlowTrafficDecision {
        FlowTrafficDecision(
            disposition: .reject,
            reason: .contextUnavailable(.fakeIPResolutionUnavailable)
        )
    }

    static func resolve(
        endpoint: FlowRemoteEndpoint,
        sourceIdentity: String,
        revision: UInt64,
        generation: UUID,
        allocator: NativeFakeIPAllocator?
    ) -> NativeFakeIPFlowDestinationResolution {
        guard let address = try? IPAddress(endpoint.host), isFakeIP(address) else {
            return .notFakeIP
        }
        guard let allocator,
              let resolution = allocator.resolution(
                  for: address,
                  sourceIdentity: sourceIdentity,
                  revision: revision,
                  generation: generation
              ),
              let realAddress = resolution.realAddresses.first(where: { $0.family == .ipv4 }) else {
            return .unavailable
        }
        return .resolved(
            endpoint: FlowRemoteEndpoint(host: realAddress.presentation, port: endpoint.port),
            hostname: resolution.hostname
        )
    }

    static func isFakeIP(_ address: IPAddress) -> Bool {
        guard address.family == .ipv4, address.bytes.count == 4 else { return false }
        return address.bytes[0] == 198 && (address.bytes[1] == 18 || address.bytes[1] == 19)
    }
}
