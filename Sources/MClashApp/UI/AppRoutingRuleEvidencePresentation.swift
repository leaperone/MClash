import Foundation
import MClashNetworkShared

struct AppRoutingRuleEvidencePresentation: Equatable {
    struct Row: Equatable, Identifiable {
        let title: String
        let value: String

        var id: String { title }
    }

    let summary: String
    let rows: [Row]
    let consequence: String?
    let symbol: String

    static func make(for activity: AppRoutingActivity) -> Self {
        guard let evidence = activity.ruleEvidence else {
            return Self(
                summary: "This activity was recorded before detailed match evidence was available.",
                rows: [],
                consequence: legacyConsequence(for: activity),
                symbol: "questionmark.circle"
            )
        }

        switch evidence.outcome {
        case .matchedRule:
            return Self(
                summary: "These are the exact alternatives that matched inside each rule field. The fields themselves were combined with AND.",
                rows: matchedRows(evidence),
                consequence: nil,
                symbol: "checkmark.seal.fill"
            )
        case .builtInBypass:
            return Self(
                summary: builtInBypassSummary(evidence.builtInBypassReason),
                rows: [],
                consequence: "The built-in safety rule took precedence over user rules and sent the flow Direct.",
                symbol: "shield.checkered"
            )
        case .defaultDirect:
            return Self(
                summary: "No enabled App Routing rule matched this flow.",
                rows: [],
                consequence: "The built-in default applied Direct routing.",
                symbol: "arrow.right.circle"
            )
        case .captureDisabled:
            return Self(
                summary: "App Routing was disabled when this flow arrived.",
                rows: [],
                consequence: "Rules were not evaluated and the flow was handed back to macOS.",
                symbol: "pause.circle"
            )
        case .configurationUnavailable:
            return Self(
                summary: "The Network Extension could not load a validated rule snapshot.",
                rows: [],
                consequence: "Rules were not evaluated and the flow was handed back to macOS (fail-open).",
                symbol: "doc.badge.exclamationmark"
            )
        case .contextUnavailable:
            return Self(
                summary: contextUnavailableSummary(evidence.contextUnavailableReason),
                rows: [],
                consequence: "The source or destination could not be trusted as complete, so rules were not evaluated and the flow was handed back to macOS (fail-open).",
                symbol: "person.crop.circle.badge.questionmark"
            )
        }
    }

    private static func matchedRows(_ evidence: CaptureRuleDecisionEvidence) -> [Row] {
        [
            evidence.source.map { Row(title: "Source", value: sourceDescription($0)) },
            evidence.destination.map { Row(title: "Destination", value: destinationDescription($0)) },
            evidence.transportProtocol.map { Row(title: "Protocol", value: protocolDescription($0)) },
            evidence.destinationPort.map { Row(title: "Port", value: portDescription($0)) },
        ].compactMap { $0 }
    }

    private static func sourceDescription(_ source: RuleSourceMatchEvidence) -> String {
        switch source {
        case .unconstrained:
            "Any application or process (no source condition)"
        case let .application(application):
            joined(
                "Exact signed application identity (code-signing requirement verified)",
                labeled("Bundle", application.bundleIdentifier),
                labeled("Signing ID", application.signingIdentifier),
                labeled("Team", application.teamIdentifier)
            )
        case let .applicationIdentifierPattern(pattern):
            "Identifier pattern \(quoted(pattern.pattern)) matched the \(fieldName(pattern.matchedField)); this is a name/pattern match, not an exact signature identity"
        case let .executable(executable):
            joined(
                assuranceDescription(executable.assurance),
                executable.canonicalPath
            )
        case let .processInstance(process):
            joined(
                "Process \(process.processIdentifier)",
                assuranceDescription(process.assurance),
                process.canonicalExecutablePath
            )
        case let .userID(userID):
            "Exact user ID \(userID); this identifies the account, not one signed application"
        }
    }

    private static func destinationDescription(_ destination: RuleDestinationMatchEvidence) -> String {
        switch destination {
        case .unconstrained:
            "Any host or IP (no destination condition)"
        case let .ip(address):
            "Exact IP \(address.presentation)"
        case let .network(network):
            "CIDR \(network.presentation)"
        case let .host(host):
            switch host.kind {
            case .exact: "Exact host \(host.value)"
            case .suffix: "Host suffix \(host.value) (the base host or a subdomain)"
            }
        case let .hostPattern(pattern):
            "Hostname pattern \(quoted(pattern.pattern))"
        }
    }

    private static func protocolDescription(_ transportProtocol: RuleProtocolMatchEvidence) -> String {
        switch transportProtocol {
        case .unconstrained: "TCP or UDP (no protocol condition)"
        case let .exact(value): "Exact protocol \(value.rawValue.uppercased())"
        }
    }

    private static func portDescription(_ port: RulePortMatchEvidence) -> String {
        switch port {
        case .unconstrained:
            "Any destination port (no port condition)"
        case let .range(range) where range.lowerBound == range.upperBound:
            "Exact destination port \(range.lowerBound)"
        case let .range(range):
            "Destination port range \(range.lowerBound)–\(range.upperBound)"
        }
    }

    private static func assuranceDescription(_ assurance: RuleSourceIdentityAssurance) -> String {
        switch assurance {
        case .verifiedCodeSignatureRequirement:
            "Exact signed application identity"
        case .identifierPattern:
            "Application identifier pattern"
        case .exactExecutablePath:
            "Exact executable path only (no signature or hash constraint)"
        case .exactExecutablePathAndCodeSignatureRequirement:
            "Exact executable path and verified code-signing requirement"
        case .exactExecutablePathAndSHA256:
            "Exact executable path and SHA-256"
        case .exactExecutablePathCodeSignatureRequirementAndSHA256:
            "Exact executable path, verified code-signing requirement, and SHA-256"
        case .exactAuditToken:
            "Exact running process identity verified by audit token"
        case .exactProcessStartTimeAndExecutablePath:
            "Exact PID, process start time, and executable path"
        case .exactUserIdentifier:
            "Exact user ID"
        }
    }

    private static func fieldName(_ field: RuleApplicationIdentifierField) -> String {
        switch field {
        case .bundleIdentifier: "bundle identifier"
        case .signingIdentifier: "signing identifier"
        case .executableName: "executable name"
        }
    }

    private static func contextUnavailableSummary(
        _ reason: RuleContextUnavailableReason?
    ) -> String {
        switch reason {
        case .missingSourceApplicationAuditToken:
            "macOS did not provide a source application audit token."
        case .sourceIdentityResolutionFailed:
            "The source process identity or its code signature could not be resolved."
        case .sourceIdentityAuditTokenMismatch:
            "The resolved process identity did not belong to the flow's audit token."
        case .sourceSigningIdentifierMismatch:
            "The flow metadata signing identifier disagreed with the verified running code."
        case .emptyRemoteHost:
            "The flow did not provide a destination host."
        case .invalidRemotePort:
            "The flow did not provide a valid destination port."
        case .unsupportedRemoteEndpoint:
            "The flow used a destination endpoint type that App Routing cannot match."
        case nil:
            "The trusted rule context was unavailable."
        }
    }

    private static func builtInBypassSummary(_ reason: BuiltInBypassReason?) -> String {
        switch reason {
        case .trustedMClashComponent:
            "The source is an exactly verified MClash component."
        case .loopback:
            "The destination is a loopback address."
        case .linkLocal:
            "The destination is a link-local address."
        case .multicast:
            "The destination is a multicast address."
        case .unspecifiedAddress:
            "The destination is an unspecified address."
        case nil:
            "A built-in safety bypass matched this flow."
        }
    }

    private static func legacyConsequence(for activity: AppRoutingActivity) -> String {
        switch activity.cause {
        case .contextUnavailable:
            "Rules were not evaluated and the flow was handed back to macOS (fail-open)."
        case .captureDisabled, .configurationUnavailable:
            "The flow was handed back to macOS without a rule match."
        case .rule, .mihomoUnavailable:
            "The recorded rule ID and outcome remain available above."
        }
    }

    private static func labeled(_ label: String, _ value: String?) -> String? {
        value.map { "\(label) \($0)" }
    }

    private static func joined(_ values: String?...) -> String {
        values.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }

    private static func quoted(_ value: String) -> String {
        "“\(value)”"
    }
}
