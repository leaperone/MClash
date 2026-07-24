enum NetworkExtensionControlReducer {
    static func reduce(
        _ state: NetworkExtensionControlState,
        _ event: NetworkExtensionControlEvent
    ) throws -> NetworkExtensionControlState {
        var next = state

        switch event {
        case let .beginEnable(revision, dnsEnabled):
            guard state.phase == .inactive || state.phase == .uninstalled else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = .activatingSystemExtension
            next.revision = revision
            next.dnsRequested = dnsEnabled
            next.userApprovalRequired = false
            next.failure = nil

        case .systemExtensionNeedsApproval:
            // The delegate callback can race with successful completion. Keep
            // approval as historical state even if the completion event was
            // already reduced by the actor.
            guard state.phase != .inactive && state.phase != .uninstalled else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.userApprovalRequired = true

        case .systemExtensionActivated:
            guard state.phase == .activatingSystemExtension else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = .configuringTransparentProxy

        case .transparentProxyConfigured:
            guard state.phase == .configuringTransparentProxy else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = .startingTransparentProxy

        case .transparentProxyStarted:
            guard state.phase == .startingTransparentProxy else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = state.dnsRequested ? .configuringDNSProxy : .running

        case .dnsProxyConfigured:
            guard state.phase == .configuringDNSProxy else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = .running

        case .beginDisable:
            guard state.phase != .inactive,
                  state.phase != .uninstalled,
                  state.phase != .deactivatingSystemExtension else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = .disablingDNSProxy
            next.failure = nil

        case .dnsProxyDisabled:
            guard state.phase == .disablingDNSProxy else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = .stoppingTransparentProxy

        case .transparentProxyStopped:
            guard state.phase == .stoppingTransparentProxy else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next = .inactive

        case .beginDeactivation:
            guard state.phase == .inactive || state.phase == .uninstalled else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = .deactivatingSystemExtension
            next.userApprovalRequired = false
            next.failure = nil

        case .systemExtensionDeactivated:
            guard state.phase == .deactivatingSystemExtension else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = .uninstalled
            next.revision = nil
            next.dnsRequested = false

        case .rebootRequired:
            guard state.phase == .activatingSystemExtension
                    || state.phase == .deactivatingSystemExtension
            else {
                throw NetworkExtensionStateReductionError.invalidTransition(
                    phase: state.phase,
                    event: event
                )
            }
            next.phase = .requiresReboot

        case let .failed(failure):
            next.phase = .failed
            next.failure = failure
        }

        return next
    }
}
